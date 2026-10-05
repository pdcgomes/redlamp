// Makes a synthetic focus bracket for the regression suite (ARC-08):
//
//     swift scripts/make-focus-bracket.swift <photo.jpg> <folder> [frames]
//
// Each frame is the photo sharp in one vertical band and blurred elsewhere, the band moving
// across the frames, with identical capture settings a second apart, as a camera's focus
// bracket has: what the stack detector looks for.
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let photo = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("usage: make-focus-bracket.swift <photo.jpg> <folder> [frames]\n".utf8))
    exit(2)
}

let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
let frames = arguments.count > 3 ? Int(arguments[3]) ?? 5 : 5
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let image = CIImage(cgImage: photo)
let extent = image.extent
let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: extent)
let context = CIContext()

for index in 0 ..< frames {
    let band = CGRect(
        x: extent.width * CGFloat(index) / CGFloat(frames), y: 0, width: extent.width / CGFloat(frames),
        height: extent.height,
    )
    let mask = CIImage(color: .white).cropped(to: band)
        .composited(over: CIImage(color: .black).cropped(to: extent))
        .applyingGaussianBlur(sigma: 25).cropped(to: extent)
    let frame = image.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: mask,
    ])
    guard let rendered = context.createCGImage(frame, from: extent) else { exit(1) }
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Redlamp", kCGImagePropertyTIFFModel: "Bracket"],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: String(format: "2026:10:05 12:00:%02d", index),
            kCGImagePropertyExifExposureTime: 0.008,
            kCGImagePropertyExifFNumber: 8.0,
            kCGImagePropertyExifISOSpeedRatings: [100],
            kCGImagePropertyExifFocalLength: 90.0,
            kCGImagePropertyExifLensModel: "Bracket 90 mm Macro",
        ],
    ]
    let url = folder.appending(path: String(format: "Bracket_%02d.jpg", index + 1))
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { exit(1) }
    CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}
