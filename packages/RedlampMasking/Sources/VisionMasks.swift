import CoreGraphics
import CoreVideo
import Foundation
import RedlampEngineAPI
import Vision

/// A mask a provider computed, before it becomes an `AIMask` in an edit.
public struct ProvidedMask: Sendable {
    public var kind: MaskKind
    public var provider: String
    public var revision: Int
    public var instance: Int?
    public var part: PersonPart?
    public var mask: GrayMask

    public init(
        kind: MaskKind,
        provider: String,
        revision: Int,
        instance: Int? = nil,
        part: PersonPart? = nil,
        mask: GrayMask,
    ) {
        self.kind = kind
        self.provider = provider
        self.revision = revision
        self.instance = instance
        self.part = part
        self.mask = mask
    }
}

/// Subject, Background, People and face parts from Apple Vision, which ships its models with
/// the OS: nothing to download. Vision sees the analysis render (the photo with no edit, sRGB,
/// about 2048 px), so masks don't move when the edit changes.
///
/// Vision's masks are low resolution (the subject's label map is 512²), so they are refined
/// against the photo with a guided filter and stored at `storedLongEdge`.
public struct VisionMaskProvider: Sendable {
    public static let storedLongEdge = 1536
    /// Face parts are small: kept at a higher resolution.
    public static let partsLongEdge = 2048

    public init() {}

    public static let supportedKinds: Set<MaskKind> = [.subject, .background, .people]

    public func masks(for request: MaskRequest, in image: CGImage) throws -> [ProvidedMask] {
        switch request.kind {
        case .subject:
            return try [subject(image)]
        case .background:
            var mask = try subject(image)
            mask.kind = .background
            mask.mask = mask.mask.inverted
            return [mask]
        case .people:
            return request.part == .entirePerson ? try people(image) : try personParts(request.part, in: image)
        default:
            throw MaskComputationError.unsupported(request.kind)
        }
    }

    // MARK: - Subject

    private func subject(_ image: CGImage) throws -> ProvidedMask {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw MaskComputationError.nothingFound(.subject)
        }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let mask = try Self.gray(buffer).fitted(longEdge: Self.storedLongEdge)
        return ProvidedMask(
            kind: .subject, provider: "apple.vision.foreground", revision: request.revision,
            mask: GuidedFilter.refine(mask, guide: image),
        )
    }

    // MARK: - People

    /// One mask per person. Vision separates up to four; beyond that (or when it separates
    /// none) the all-people matte is used as one.
    private func people(_ image: CGImage) throws -> [ProvidedMask] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let instances = VNGeneratePersonInstanceMaskRequest()
        try handler.perform([instances])
        if let observation = instances.results?.first, !observation.allInstances.isEmpty,
           observation.allInstances.count < 4 {
            return try covering(faces: observation.allInstances.sorted().enumerated().map { index, instance in
                let buffer = try observation.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: instance), from: handler,
                )
                let mask = try Self.gray(buffer).fitted(longEdge: Self.storedLongEdge)
                return ProvidedMask(
                    kind: .people, provider: "apple.vision.personInstance", revision: instances.revision,
                    instance: index, part: .entirePerson, mask: GuidedFilter.refine(mask, guide: image),
                )
            }, image: image, handler: handler)
        }
        let mask = try allPeople(image, handler: handler)
        guard mask.coveredFraction > 0.001 else { throw MaskComputationError.nothingFound(.people) }
        return covering(faces: [ProvidedMask(
            kind: .people, provider: "apple.vision.personSegmentation", revision: 1, part: .entirePerson,
            mask: GuidedFilter.refine(mask, guide: image),
        )], image: image, handler: handler)
    }

    /// Vision's person segmentation can miss a head in a dark, low-key photo that its foreground
    /// (Subject) mask has. Each detected face the people masks leave mostly uncovered gets the part
    /// of the Subject mask connected to it, added to the person it overlaps most.
    private func covering(
        faces masks: [ProvidedMask], image: CGImage, handler: VNImageRequestHandler,
    ) -> [ProvidedMask] {
        let request = VNDetectFaceRectanglesRequest()
        guard let first = masks.first, (try? handler.perform([request])) != nil,
              let faces = request.results, !faces.isEmpty
        else { return masks }
        let width = first.mask.width
        let height = first.mask.height
        let everyone = masks.dropFirst().reduce(first.mask) { $0.union($1.mask) }
        /// Vision's boxes are normalised, from the bottom left.
        func pixels(_ face: VNFaceObservation) -> (x: Range<Int>, y: Range<Int>) {
            let box = face.boundingBox
            let x0 = min(max(Int(box.minX * Double(width)), 0), width - 1)
            let x1 = min(max(Int(box.maxX * Double(width)), x0 + 1), width)
            let y0 = min(max(Int((1 - box.maxY) * Double(height)), 0), height - 1)
            let y1 = min(max(Int((1 - box.minY) * Double(height)), y0 + 1), height)
            return (x0 ..< x1, y0 ..< y1)
        }
        let uncovered = faces.filter { face in
            let box = pixels(face)
            var sum = 0
            for y in box.y {
                for x in box.x {
                    sum += Int(everyone[x, y])
                }
            }
            return Double(sum) / Double(255 * box.x.count * box.y.count) < 0.5
        }
        guard !uncovered.isEmpty,
              let subject = try? subject(image).mask.resized(to: PixelSize(width: width, height: height))
        else { return masks }
        var masks = masks
        for face in uncovered {
            let box = pixels(face)
            let centre = (box.y.lowerBound + box.y.upperBound) / 2 * width + (box.x.lowerBound + box.x.upperBound) / 2
            guard subject.pixels[centre] > 127 else { continue }
            var part = [UInt8](repeating: 0, count: width * height)
            var stack = [centre]
            part[centre] = subject.pixels[centre]
            while let index = stack.popLast() {
                let x = index % width
                for next in [x > 0 ? index - 1 : -1, x < width - 1 ? index + 1 : -1, index - width, index + width]
                    where next >= 0 && next < part.count && part[next] == 0 && subject.pixels[next] > 127 {
                    part[next] = subject.pixels[next]
                    stack.append(next)
                }
            }
            let piece = GrayMask(width: width, height: height, pixels: part)
            let overlaps = masks.map { mask in zip(mask.mask.pixels, part).reduce(0) { $0 + Int(min($1.0, $1.1)) } }
            let target = overlaps.indices.max { overlaps[$0] < overlaps[$1] } ?? 0
            masks[target].mask = masks[target].mask.union(piece)
        }
        return masks
    }

    private func allPeople(_ image: CGImage, handler: VNImageRequestHandler) throws -> GrayMask {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { throw MaskComputationError.nothingFound(.people) }
        // The matte has a fixed 4:3 size whatever the photo's shape.
        return try Self.gray(buffer).resized(
            to: PixelSize(width: image.width, height: image.height)
                .fitted(within: PixelSize(width: Self.storedLongEdge, height: Self.storedLongEdge)),
        )
    }

    // MARK: - Face parts

    /// Lips, eyebrows, eyes, iris and face skin drawn from Vision's 76 face landmarks, feathered
    /// a little. Face skin is the face outline within the person, less the features. Teeth are
    /// the bright, pale pixels inside the lips. Hair needs an embedded matte (see `EmbeddedMattes`)
    /// or SAM 3, as do facial hair, body skin and clothes (`SAM3Concepts`).
    private func personParts(_ part: PersonPart, in image: CGImage) throws -> [ProvidedMask] {
        guard !SAM3Concepts.partPrecedence.contains(part) else { throw MaskComputationError.unsupported(.people) }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceLandmarksRequest()
        try handler.perform([faces])
        let observations = (faces.results ?? []).filter { $0.landmarks != nil }
        guard !observations.isEmpty else { throw MaskComputationError.nothingFound(.people) }
        let size = PixelSize(width: image.width, height: image.height)
            .fitted(within: PixelSize(width: Self.partsLongEdge, height: Self.partsLongEdge))
        let people = part == .faceSkin ? try? allPeople(image, handler: handler).resized(to: size) : nil
        let pixels = part == .teeth ? RGBImage(image, size: size) : nil
        return observations.enumerated().compactMap { index, face in
            guard let landmarks = face.landmarks,
                  var mask = FaceParts.mask(part, landmarks: landmarks, size: size, people: people, pixels: pixels),
                  mask.coveredFraction > 0
            else { return nil }
            mask = mask.blurred(radius: max(1, size.longEdge / 1000))
            return ProvidedMask(
                kind: .people, provider: "redlamp.faceLandmarks", revision: faces.revision, instance: index,
                part: part, mask: mask,
            )
        }
    }

    // MARK: - Helpers

    /// A one-component 8-bit or 32-bit float pixel buffer as a gray mask.
    static func gray(_ buffer: CVPixelBuffer) throws -> GrayMask {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw MaskComputationError.nothingFound(.subject) }
        var pixels = [UInt8](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0 ..< height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0 ..< width {
                    pixels[y * width + x] = UInt8((min(max(row[x], 0), 1) * 255).rounded())
                }
            }
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0 ..< height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0 ..< width {
                    pixels[y * width + x] = UInt8((min(max(Float(row[x]), 0), 1) * 255).rounded())
                }
            }
        default:
            for y in 0 ..< height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0 ..< width {
                    pixels[y * width + x] = row[x]
                }
            }
        }
        return GrayMask(width: width, height: height, pixels: pixels)
    }
}

/// 8-bit RGB pixels of an image at a size, for colour tests such as teeth.
struct RGBImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage, size: PixelSize) {
        width = size.width
        height = size.height
        var data = [UInt8](repeating: 0, count: size.width * size.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size.width, height: size.height, bitsPerComponent: 8,
                bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            return true
        }
        guard drawn else { return nil }
        pixels = data
    }

    func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let index = (y * width + x) * 4
        return SIMD3(Float(pixels[index]), Float(pixels[index + 1]), Float(pixels[index + 2])) / 255
    }
}
