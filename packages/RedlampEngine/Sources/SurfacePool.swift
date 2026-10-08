import CoreVideo
import Foundation
import IOSurface
import Metal
import RedlampEngineAPI

/// A ring of IOSurface-backed render targets.
///
/// Three surfaces let the engine render into one while the UI displays another without
/// tearing. A frame renders into the top-left of the next surface through a texture of exactly
/// its size, whose rows are the surface's, so frames whose size changes as the view is pinched
/// or resized keep the surfaces they had. A surface is made, one at a time, when the next one
/// is too small or holds more than twice what recent frames need, at their largest size.
final class SurfacePool {
    struct Target {
        let surface: IOSurfaceRef
        let texture: any MTLTexture
    }

    private struct Slot {
        let surface: IOSurfaceRef
        let capacity: PixelSize
        var target: Target
    }

    /// The frames whose sizes a new surface is made to hold.
    static let recentSizes = 32
    /// New surfaces' sides are multiples of this, so a size growing a little at a time, as in a
    /// pinch, fits the surfaces it has for a while.
    static let rounding = 256

    private let device: any MTLDevice
    private var slots: [Slot?] = [nil, nil, nil]
    private var recent: [PixelSize] = []
    private var cursor = 0
    /// Surfaces made so far, for tests.
    private(set) var surfacesMade = 0

    /// The targets' textures, for tests.
    var textures: [any MTLTexture] {
        slots.compactMap { $0?.target.texture }
    }

    init(device: any MTLDevice) {
        self.device = device
    }

    func next(size: PixelSize) throws -> Target {
        recent.append(size)
        if recent.count > Self.recentSizes {
            recent.removeFirst()
        }
        cursor = (cursor + 1) % slots.count
        if let slot = slots[cursor], slot.target.texture.width == size.width,
           slot.target.texture.height == size.height {
            return slot.target
        }
        func rounded(_ length: Int) -> Int {
            (length + Self.rounding - 1) / Self.rounding * Self.rounding
        }
        let largest = PixelSize(
            width: rounded(recent.map(\.width).max() ?? size.width),
            height: rounded(recent.map(\.height).max() ?? size.height),
        )
        var surface: IOSurfaceRef
        var capacity: PixelSize
        if let slot = slots[cursor], slot.capacity.width >= size.width, slot.capacity.height >= size.height,
           slot.capacity.width * slot.capacity.height <= 2 * largest.width * largest.height {
            (surface, capacity) = (slot.surface, slot.capacity)
        } else {
            capacity = largest
            surface = try makeSurface(capacity)
        }
        let target = try Target(surface: surface, texture: makeTexture(size, on: surface))
        slots[cursor] = Slot(surface: surface, capacity: capacity, target: target)
        return target
    }

    /// Frees the surfaces until the next `next(size:)`.
    func removeAll() {
        slots = [nil, nil, nil]
        recent = []
    }

    private func makeSurface(_ size: PixelSize) throws -> IOSurfaceRef {
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
        return surface
    }

    private func makeTexture(_ size: PixelSize, on surface: IOSurfaceRef) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            throw EngineError.gpuUnavailable
        }
        return texture
    }
}
