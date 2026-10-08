import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Flat sRGB grey frames (0.46), each labelled in its top-left corner, for DEC-08's mask test.
/// Copy this folder somewhere scratch, run `swift make-grey.swift .` in it, then `redlamp task new --draft draft.json`.
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let labels = [
    ("0-baseline", "0 · BASELINE"),
    ("1-gradient-a", "1 · GRADIENT A"),
    ("2-gradient-b", "2 · GRADIENT B"),
    ("3-intersect", "3 · A ∩ B"),
]
let width = 2400, height = 1600
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for (name, text) in labels {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 16,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little
            .rawValue,
    )!
    context.setFillColor(CGColor(colorSpace: space, components: [0.46, 0.46, 0.46, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
            colorSpace: space,
            components: [0.08, 0.08, 0.08, 1],
        )!,
    ]
    context.textPosition = CGPoint(x: 48, y: CGFloat(height) - 104)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    let image = context.makeImage()!
    let url = out.appending(path: "\(name).tif")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print(url.path)
}
