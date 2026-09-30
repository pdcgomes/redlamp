// Scores a side-by-side parity capture (scripts/harness-capture.sh <scene> <png> side):
// finds the two panels, compares them pixel by pixel, and prints how far apart they are.
// Writes an amplified heatmap of the differences next to the capture.
//
// usage: swift scripts/parity-diff.swift capture.png
import AppKit

let path = CommandLine.arguments[1]
let image = NSImage(contentsOfFile: path)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
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

func isPanel(_ p: (Int, Int, Int)) -> Bool {
    abs(p.0 - 29) <= 1 && abs(p.1 - 29) <= 1 && abs(p.2 - 29) <= 1
}

/// The two panels: the first row with two long runs of panel background.
var boxes: [(x: Int, y: Int, w: Int)] = []
search: for y in 0 ..< height {
    var runs: [(Int, Int)] = []
    var x = 0
    while x < width {
        if isPanel(pixel(x, y)) {
            let start = x
            while x < width, isPanel(pixel(x, y)) {
                x += 1
            }
            if x - start > 200 {
                runs.append((start, x - start))
            }
        } else {
            x += 1
        }
    }
    if runs.count == 2 {
        boxes = runs.map { ($0.0, y, $0.1) }
        break search
    }
}

guard boxes.count == 2 else {
    print("could not find two panels")
    exit(1)
}

let (left, right) = (boxes[0], boxes[1])
let boxWidth = min(left.w, right.w)
var boxHeight = 0
while left.y + boxHeight < height, isPanel(pixel(left.x + 1, left.y + boxHeight)) || isPanel(pixel(
    left.x + boxWidth - 2,
    left.y + boxHeight,
)) {
    boxHeight += 1
}

let heat = CGContext(
    data: nil, width: boxWidth, height: boxHeight, bitsPerComponent: 8, bytesPerRow: boxWidth * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
)!
let heatPixels = heat.data!.bindMemory(to: UInt8.self, capacity: boxWidth * boxHeight * 4)
var total = 0, over8 = 0, over24 = 0, maxDelta = 0, sum = 0
var worstRows: [Int: Int] = [:]
for y in 0 ..< boxHeight {
    for x in 0 ..< boxWidth {
        let a = pixel(left.x + x, left.y + y), b = pixel(right.x + x, right.y + y)
        let delta = max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
        total += 1
        sum += delta
        maxDelta = max(maxDelta, delta)
        if delta > 8 {
            over8 += 1
        }
        if delta > 24 {
            over24 += 1
            worstRows[y, default: 0] += 1
        }
        let i = (y * boxWidth + x) * 4
        let v = UInt8(min(255, delta * 6))
        heatPixels[i] = v
        heatPixels[i + 1] = delta > 24 ? 0 : v
        heatPixels[i + 2] = delta > 24 ? 0 : v
        heatPixels[i + 3] = 255
    }
}

let heatPath = (path as NSString).deletingPathExtension + "-heat.png"
try! NSBitmapImageRep(cgImage: heat.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: heatPath))

print(String(
    format: "panels %d×%d: mean Δ %.2f, >8: %.2f%%, >24: %.2f%% (%d px), max Δ %d",
    boxWidth, boxHeight, Double(sum) / Double(total), Double(over8) / Double(total) * 100,
    Double(over24) / Double(total) * 100, over24, maxDelta,
))
if !worstRows.isEmpty {
    let rows = worstRows.sorted { $0.value > $1.value }.prefix(8).map { "y\($0.key):\($0.value)" }
    print("rows with the most >24 pixels: " + rows.joined(separator: " "))
}

print("heatmap: \(heatPath)")
