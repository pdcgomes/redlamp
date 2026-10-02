// Compares two ways to make a 192 px filmstrip thumbnail from a raw file:
//   A. ImageIO: CGImageSourceCreateThumbnailAtIndex on the file (what Redlamp does today).
//   B. LibRaw: parse the container, pick the smallest embedded JPEG preview whose long edge is at
//      least 192 px, read only those bytes, and decode them with ImageIO at 192 px.
// Up to 20 files: each path's best time of five per file. More: throughput over distinct files on
// <threads> threads, each path on its own half of the files (first opens). Build and run with
// run.sh beside this file.
// Usage: libraw_thumbs <threads> <files...>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <LibRaw/libraw.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

static const int kSize = 192;

// `always`: decode the image itself, not a JPEG's own (often 160 px) EXIF thumbnail.
static CFDictionaryRef ThumbnailOptions(bool always = false) {
    static CFDictionaryRef options[2] = {nullptr, nullptr};
    if (!options[always]) {
        int size = kSize;
        CFNumberRef number = CFNumberCreate(nullptr, kCFNumberIntType, &size);
        const void *keys[] = {always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent,
                              kCGImageSourceCreateThumbnailWithTransform, kCGImageSourceThumbnailMaxPixelSize,
                              kCGImageSourceShouldCacheImmediately};
        const void *values[] = {kCFBooleanTrue, kCFBooleanTrue, number, kCFBooleanTrue};
        options[always] = CFDictionaryCreate(nullptr, keys, values, 4, &kCFTypeDictionaryKeyCallBacks,
                                             &kCFTypeDictionaryValueCallBacks);
    }
    return options[always];
}

struct Result {
    int width = 0, height = 0;
    int previewWidth = 0, previewHeight = 0;  // B: the preview chosen
    size_t bytes = 0;                         // B: bytes read
};

static Result ImageIOThumbnail(const std::string &path) {
    Result result;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, (const UInt8 *)path.c_str(), path.size(), false);
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, nullptr);
    CFRelease(url);
    if (!source) return result;
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, ThumbnailOptions());
    if (image) {
        result.width = (int)CGImageGetWidth(image);
        result.height = (int)CGImageGetHeight(image);
        CGImageRelease(image);
    }
    CFRelease(source);
    return result;
}

static Result LibRawThumbnail(const std::string &path) {
    Result result;
    libraw_data_t *raw = libraw_init(0);
    if (!raw) return result;
    if (libraw_open_file(raw, path.c_str()) != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return result;
    }
    const libraw_thumbnail_list_t &list = raw->thumbs_list;
    int best = -1;
    for (int i = 0; i < list.thumbcount; ++i) {
        const libraw_thumbnail_item_t &item = list.thumblist[i];
        if (item.tformat != LIBRAW_INTERNAL_THUMBNAIL_JPEG || item.tlength == 0) continue;
        int edge = std::max(item.twidth, item.theight);
        // Unknown sizes (0) are taken only if nothing better is listed.
        if (edge != 0 && edge < kSize) continue;
        if (best < 0) { best = i; continue; }
        int bestEdge = std::max(list.thumblist[best].twidth, list.thumblist[best].theight);
        if (bestEdge == 0 || (edge != 0 && edge < bestEdge)) best = i;
    }
    if (best < 0) {
        libraw_close(raw);
        return result;
    }
    const libraw_thumbnail_item_t item = list.thumblist[best];
    libraw_close(raw);
    result.previewWidth = item.twidth;
    result.previewHeight = item.theight;
    std::vector<uint8_t> bytes(item.tlength);
    int fd = open(path.c_str(), O_RDONLY);
    ssize_t read = pread(fd, bytes.data(), bytes.size(), (off_t)item.toffset);
    close(fd);
    if (read != (ssize_t)bytes.size()) return result;
    result.bytes = bytes.size();
    CFDataRef data = CFDataCreateWithBytesNoCopy(nullptr, bytes.data(), bytes.size(), kCFAllocatorNull);
    CGImageSourceRef source = CGImageSourceCreateWithData(data, nullptr);
    if (source) {
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, ThumbnailOptions(true));
        if (image) {
            result.width = (int)CGImageGetWidth(image);
            result.height = (int)CGImageGetHeight(image);
            CGImageRelease(image);
        }
        CFRelease(source);
    }
    CFRelease(data);
    return result;
}

static double Seconds(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

int main(int argc, char **argv) {
    if (argc < 3) return 1;
    int threads = atoi(argv[1]);
    std::vector<std::string> files(argv + 2, argv + argc);

    if (files.size() <= 20) {
        // Per file: what each path decodes, and its best time of five (warm cache).
        for (const auto &file : files) {
            double a = 1e9, b = 1e9;
            Result ra, rb;
            for (int run = 0; run < 5; ++run) {
                auto start = std::chrono::steady_clock::now();
                ra = ImageIOThumbnail(file);
                a = std::min(a, Seconds(start));
                start = std::chrono::steady_clock::now();
                rb = LibRawThumbnail(file);
                b = std::min(b, Seconds(start));
            }
            std::string name = file.substr(file.find_last_of('/') + 1);
            printf("%-46s ImageIO %3dx%-3d %6.1f ms | LibRaw preview %4dx%-4d (%6zu KB) -> %3dx%-3d %6.1f ms  %4.1fx\n",
                   name.c_str(), ra.width, ra.height, a * 1000, rb.previewWidth, rb.previewHeight, rb.bytes / 1024,
                   rb.width, rb.height, b * 1000, a / b);
        }
        return 0;
    }

    // Throughput over distinct files (first open of each), on `threads` threads.
    for (int pass = 0; pass < 2; ++pass) {
        bool libraw = pass == 1;
        std::atomic<size_t> next{0}, made{0};
        size_t half = files.size() / 2;
        size_t begin = libraw ? half : 0, end = libraw ? files.size() : half;
        auto start = std::chrono::steady_clock::now();
        std::vector<std::thread> workers;
        for (int t = 0; t < threads; ++t) {
            workers.emplace_back([&] {
                for (size_t i; (i = begin + next++) < end;) {
                    Result r = libraw ? LibRawThumbnail(files[i]) : ImageIOThumbnail(files[i]);
                    if (r.width > 0) ++made;
                }
            });
        }
        for (auto &worker : workers) worker.join();
        double elapsed = Seconds(start);
        printf("%s: %zu thumbnails from %zu distinct files on %d threads in %.2f s, %.0f a second\n",
               libraw ? "LibRaw " : "ImageIO", made.load(), end - begin, threads, elapsed, made / elapsed);
    }
    return 0;
}
