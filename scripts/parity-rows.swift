// Compares the two panels in a side-by-side parity capture (scripts/harness-capture.sh
// <scene> <png> side), band by band: each run of rows that contains anything other than the
// panel background is an element, and elements are paired top to bottom.
//
// usage: swift scripts/parity-rows.swift capture.png
import AppKit

let image = NSImage(contentsOfFile: CommandLine.arguments[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let width = image.width, height = image.height
let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
)!
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)

func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * width + x) * 4
    return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
}

let panel = 29 // Palette.panelBackground, 0.115 × 255
/// Captures use a black stage; the panels are everything else.
func isStageColor(_ p: (Int, Int, Int)) -> Bool {
    p.0 <= 3 && p.1 <= 3 && p.2 <= 3
}

func isPanel(_ p: (Int, Int, Int)) -> Bool {
    abs(p.0 - panel) <= 1 && abs(p.1 - panel) <= 1 && abs(p.2 - panel) <= 1
}

/// The two boxes: the widest horizontal runs of panel background on some row.
func boxes() -> [(x: Int, y: Int, w: Int, h: Int)] {
    var found: [(x: Int, y: Int, w: Int, h: Int)] = []
    for y in stride(from: 0, to: height, by: 1) {
        var x = 0
        var runs: [(Int, Int)] = []
        while x < width {
            if !isStageColor(pixel(x, y)) {
                let start = x
                while x < width, !isStageColor(pixel(x, y)) {
                    x += 1
                }
                if x - start > 200 {
                    runs.append((start, x - start))
                }
            } else {
                x += 1
            }
        }
        // The two panels are the same width, 24 pt apart (the parity stage's gap).
        if let pair = zip(runs, runs.dropFirst())
            .first(where: { abs($0.0.1 - $0.1.1) <= 1 && $0.1.0 - ($0.0.0 + $0.0.1) == 24 }) {
            for (x0, w) in [pair.0, pair.1] {
                var y1 = y
                while y1 < height, !isStageColor(pixel(x0 + 1, y1)) {
                    y1 += 1
                }
                found.append((x0, y, w, y1 - y))
            }
            return found
        }
    }
    return found
}

func bands(_ box: (x: Int, y: Int, w: Int, h: Int)) -> [(y0: Int, y1: Int, x0: Int, x1: Int)] {
    var result: [(Int, Int, Int, Int)] = []
    var current: (Int, Int, Int, Int)?
    for y in box.y ..< box.y + box.h {
        var x0 = Int.max, x1 = -1
        for x in box.x ..< box.x + box.w where !isPanel(pixel(x, y)) {
            x0 = min(x0, x)
            x1 = max(x1, x)
        }
        if x1 >= 0 {
            if var band = current {
                band.1 = y
                band.2 = min(band.2, x0)
                band.3 = max(band.3, x1)
                current = band
            } else {
                current = (y, y, x0, x1)
            }
        } else if let band = current {
            result.append(band)
            current = nil
        }
    }
    if let band = current {
        result.append(band)
    }
    return result.map { ($0.0 - box.y, $0.1 - box.y, $0.2 - box.x, $0.3 - box.x) }
}

let found = boxes()
guard found.count == 2 else {
    print("could not find two panel boxes")
    exit(1)
}

let reference = bands(found[0]), candidate = bands(found[1])
print(
    "boxes: SwiftUI \(found[0].w)×\(found[0].h) at \(found[0].x),\(found[0].y); AppKit \(found[1].w)×\(found[1].h) at \(found[1].x),\(found[1].y)",
)
print("band   SwiftUI y        x         AppKit y         x          Δy0  Δy1  Δx0  Δx1")
for index in 0 ..< max(reference.count, candidate.count) {
    let r = index < reference.count ? reference[index] : nil
    let c = index < candidate.count ? candidate[index] : nil
    func fmt(_ b: (y0: Int, y1: Int, x0: Int, x1: Int)?) -> String {
        guard let b else { return String(repeating: " ", count: 24) }
        return String(format: "%3d-%-3d  %3d-%-3d", b.y0, b.y1, b.x0, b.x1).padding(
            toLength: 24,
            withPad: " ",
            startingAt: 0,
        )
    }
    var delta = ""
    if let r, let c {
        delta = String(format: "%4d %4d %4d %4d", c.y0 - r.y0, c.y1 - r.y1, c.x0 - r.x0, c.x1 - r.x1)
        if c.y0 == r.y0, c.y1 == r.y1, c.x0 == r.x0, c.x1 == r.x1 {
            delta += "  ✓"
        }
    }
    print(String(format: "%3d    ", index) + fmt(r) + " " + fmt(c) + delta)
}
