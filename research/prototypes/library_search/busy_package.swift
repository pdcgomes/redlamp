// How many batches a folder-level FSEvents stream with VolumeEventStream's flags and ChangeTracker's
// 300 ms latency delivers while another app writes inside a package below the watched root, with and
// without the package left out by FSEventStreamSetExclusionPaths.
import CoreServices
import Foundation

final class Counter: @unchecked Sendable {
    var batches = 0
    var events = 0
    var namingPackage = 0
    let lock = NSLock()
}

struct Delivered {
    let batches: Int
    let events: Int
    let namingPackage: Int
}

func watch(root: String, package: String, excluding: Bool, seconds: Double, writesPerSecond: Double) -> Delivered {
    let counter = Counter()
    var context = FSEventStreamContext(
        version: 0,
        info: Unmanaged.passUnretained(counter).toOpaque(),
        retain: nil,
        release: nil,
        copyDescription: nil,
    )
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info else { return }
        let counter = Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue()
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        counter.lock.lock()
        counter.batches += 1
        counter.events += count
        counter.namingPackage += list.filter { $0.contains(".photoslibrary") }.count
        counter.lock.unlock()
    }
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
    guard let stream = FSEventStreamCreate(
        nil,
        callback,
        &context,
        [root] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.3,
        flags,
    ) else {
        fatalError("FSEventStreamCreate failed")
    }
    if excluding {
        FSEventStreamSetExclusionPaths(stream, [package] as CFArray)
    }
    FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "events"))
    FSEventStreamStart(stream)
    Thread.sleep(forTimeInterval: 1)
    counter.lock.withLock {
        counter.batches = 0
        counter.events = 0
        counter.namingPackage = 0
    }
    let file = package + "/database/Photos.sqlite-wal"
    let end = Date().addingTimeInterval(seconds)
    var written = 0
    while Date() < end {
        guard let handle = FileHandle(forWritingAtPath: file) else { fatalError("can't write \(file)") }
        handle.seekToEndOfFile()
        handle.write(Data(repeating: UInt8(written & 0xFF), count: 4096))
        try? handle.synchronize()
        handle.closeFile()
        written += 1
        Thread.sleep(forTimeInterval: 1 / writesPerSecond)
    }
    Thread.sleep(forTimeInterval: 1)
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    return counter.lock.withLock {
        Delivered(batches: counter.batches, events: counter.events, namingPackage: counter.namingPackage)
    }
}

let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("cling-study-fsevents")
let root = base + "/Pictures"
let package = root + "/Photos Library.photoslibrary"
try? FileManager.default.removeItem(atPath: base)
do {
    try FileManager.default.createDirectory(atPath: package + "/database", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: root + "/2024/2024-06-01 Lisbon", withIntermediateDirectories: true)
} catch {
    fatalError("can't make the folders: \(error)")
}

FileManager.default.createFile(atPath: package + "/database/Photos.sqlite-wal", contents: Data())
let seconds = 20.0, rate = 10.0
for excluding in [false, true] {
    let delivered = watch(root: root, package: package, excluding: excluding, seconds: seconds, writesPerSecond: rate)
    print(String(
        format: "%@: %ld batches and %ld events in %.0f s of %.0f writes a second inside the package (%ld naming it), %.1f a second",
        excluding ? "package excluded" : "root watched    ",
        delivered.batches,
        delivered.events,
        seconds,
        rate,
        delivered.namingPackage,
        Double(delivered.batches) / seconds,
    ))
}

try? FileManager.default.removeItem(atPath: base)
