import Metal

/// Work textures the detail stage let go of, written over by later renders that need one of the
/// same format and size, so a drag, a pan or an export's tiles don't allocate on every miss.
/// Idle ones are parked with the caches' textures, so the system may reclaim them, and the oldest
/// go once they would hold more than `budget`.
///
/// A render may write over one an earlier render in the same command buffer reads (an edit and
/// its comparison): Metal's hazard tracking, on for work textures, orders the writes after the
/// reads.
///
/// Owned by the engine's render queue, through `DetailStage`.
final class WorkTexturePool {
    /// Idle textures' bytes: a 1:1 view's two edits on a 1440p display, with their ladders.
    var budget = 352 << 20

    private let residency: DetailResidency
    private var idle: [any MTLTexture] = []

    init(residency: DetailResidency) {
        self.residency = residency
    }

    var heldTextures: [any MTLTexture] {
        idle
    }

    /// An idle texture of `format` and exactly `size`, made resident; nil when there's none, or
    /// the system reclaimed it.
    func take(_ format: MTLPixelFormat, _ size: SIMD2<Int>) -> (any MTLTexture)? {
        guard let index = idle.lastIndex(where: {
            $0.pixelFormat == format && $0.width == size.x && $0.height == size.y
        }) else { return nil }
        let texture = idle.remove(at: index)
        return residency.wake(texture) ? texture : nil
    }

    /// Keeps `textures`, which nothing the stage caches holds any more, to be written over.
    func give(_ textures: [any MTLTexture]) {
        for texture in textures where !idle.contains(where: { $0 === texture }) && residency.wake(texture) {
            idle.append(texture)
        }
        trim(to: budget)
    }

    /// Lets go of the oldest idle textures until they hold at most `bytes`.
    func trim(to bytes: Int) {
        var held = idle.reduce(0) { $0 + $1.allocatedSize }
        while held > bytes, !idle.isEmpty {
            held -= idle.removeFirst().allocatedSize
        }
    }

    func removeAll() {
        idle.removeAll()
    }
}
