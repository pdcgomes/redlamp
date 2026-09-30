// Apple's VideoToolbox super-resolution scaler (macOS 26) over raw float images.
// Input:  <dir>/*.bin, each "width height" as two UInt32 then width*height*3 Float32 RGB (display-encoded).
// Output: <out>/*.bin in the same format at 4x (the only factor the scaler reports on the M1 Ultra),
//         and one "<name> <seconds>" line per image on stdout.
// Usage:  swift research/prototypes/restoration/vt_superres.swift <in dir> <out dir>

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

func makeBuffer(width: Int, height: Int, attributes: [String: Any]) -> CVPixelBuffer {
    var attrs = attributes
    attrs[kCVPixelBufferWidthKey as String] = width
    attrs[kCVPixelBufferHeightKey as String] = height
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &buffer)
    precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
    return buffer!
}

func fill(_ buffer: CVPixelBuffer, rgb: [Float], width: Int, height: Int) {
    CVPixelBufferLockBaseAddress(buffer, [])
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!
    for y in 0 ..< height {
        let line = (base + y * row).assumingMemoryBound(to: Float16.self)
        for x in 0 ..< width {
            let i = (y * width + x) * 3
            line[x * 4] = Float16(rgb[i])
            line[x * 4 + 1] = Float16(rgb[i + 1])
            line[x * 4 + 2] = Float16(rgb[i + 2])
            line[x * 4 + 3] = 1
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
}

func read(_ buffer: CVPixelBuffer) -> [Float] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!
    var out = [Float](repeating: 0, count: width * height * 3)
    for y in 0 ..< height {
        let line = (base + y * row).assumingMemoryBound(to: Float16.self)
        for x in 0 ..< width {
            for c in 0 ..< 3 {
                out[(y * width + x) * 3 + c] = Float(line[x * 4 + c])
            }
        }
    }
    return out
}

/// The completion-handler form: on macOS 26.6 the async overload returned before the output was written.
func process(_ processor: VTFrameProcessor, _ parameters: VTSuperResolutionScalerParameters) throws {
    let done = DispatchSemaphore(value: 0)
    var failure: Error?
    processor.process(parameters: parameters) { _, error in
        failure = error
        done.signal()
    }
    done.wait()
    if let failure {
        throw failure
    }
}

let arguments = CommandLine.arguments
let inDir = URL(fileURLWithPath: arguments[1]), outDir = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let files = try FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "bin" }.sorted { $0.path < $1.path }

var sessions: [String: (VTFrameProcessor, VTSuperResolutionScalerConfiguration)] = [:]
for (index, file) in files.enumerated() {
    let data = try Data(contentsOf: file)
    let width = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
    let height = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
    let rgb = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)[2...]) }
    let key = "\(width)x\(height)"
    if sessions[key] == nil {
        guard let configuration = VTSuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: 4, inputType: .image,
            usePrecomputedFlow: false, qualityPrioritization: .normal, revision: .revision1,
        ) else { fatalError("no configuration for \(key)") }
        let processor = VTFrameProcessor()
        try processor.startSession(configuration: configuration)
        sessions[key] = (processor, configuration)
    }
    let (processor, configuration) = sessions[key]!
    let source = makeBuffer(width: width, height: height, attributes: configuration.sourcePixelBufferAttributes)
    let destination = makeBuffer(
        width: width * 4,
        height: height * 4,
        attributes: configuration.destinationPixelBufferAttributes,
    )
    fill(source, rgb: rgb, width: width, height: height)
    let parameters = VTSuperResolutionScalerParameters(
        sourceFrame: VTFrameProcessorFrame(buffer: source, presentationTimeStamp: .zero)!,
        previousFrame: nil, previousOutputFrame: nil, opticalFlow: nil, submissionMode: .random,
        destinationFrame: VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: .zero)!,
    )!
    if index == 0 {
        try process(processor, parameters)
    } // warm-up
    let start = Date()
    try process(processor, parameters)
    let elapsed = Date().timeIntervalSince(start)
    var header = Data()
    withUnsafeBytes(of: UInt32(width * 4)) { header.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(height * 4)) { header.append(contentsOf: $0) }
    let pixels = read(destination)
    try (header + pixels.withUnsafeBufferPointer { Data(buffer: $0) })
        .write(to: outDir.appendingPathComponent(file.lastPathComponent))
    print("\(file.deletingPathExtension().lastPathComponent) \(elapsed)")
}
