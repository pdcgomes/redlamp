import CoreVideo
import Foundation
import IOSurface
import Metal
import RedlampEngineAPI

/// A ring of IOSurface-backed render targets for one output size.
///
/// Three surfaces let the engine render into one while the UI displays another without
/// tearing; the ring is rebuilt when the requested size changes.
final class SurfacePool {
    struct Target {
        let surface: IOSurfaceRef
        let texture: any MTLTexture
    }

    private let device: any MTLDevice
    private var size = PixelSize.zero
    private var targets: [Target] = []
    private var cursor = 0
    /// Surfaces made so far, for tests.
    private(set) var surfacesMade = 0

    init(device: any MTLDevice) {
        self.device = device
    }

    func next(size: PixelSize) throws -> Target {
        if size != self.size || targets.isEmpty {
            targets = try (0 ..< 3).map { _ in try makeTarget(size) }
            self.size = size
            cursor = 0
        }
        cursor = (cursor + 1) % targets.count
        return targets[cursor]
    }

    /// Frees the surfaces until the next `next(size:)`.
    func removeAll() {
        targets = []
        size = .zero
    }

    private func makeTarget(_ size: PixelSize) throws -> Target {
        let bytesPerElement = 8
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, size.width * bytesPerElement)
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: size.width,
            kIOSurfaceHeight: size.height,
            kIOSurfaceBytesPerElement: bytesPerElement,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfacePixelFormat: kCVPixelFormatType_64RGBAHalf,
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { throw EngineError.gpuUnavailable }
        surfacesMade += 1

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            throw EngineError.gpuUnavailable
        }
        return Target(surface: surface, texture: texture)
    }
}
