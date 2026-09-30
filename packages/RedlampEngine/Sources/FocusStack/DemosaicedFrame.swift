import Metal
import RedlampServices

/// One source frame of a focus stack, decoded and demosaiced on the GPU but not yet a session:
/// full resolution, camera RGB balanced by the as-shot white balance, before any edit.
struct DemosaicedFrame {
    /// `.rgba16Float`, private storage, one level.
    let texture: any MTLTexture
    /// What normalisation multiplied camera RGB by (smallest channel 1).
    let balance: SIMD3<Double>
    /// The decode it came from, for metadata (white balance, colour matrices, orientation).
    let decoded: DecodedImage
    /// The sensor noise the demosaic used, in normalised units before white balance.
    let noise: NoiseModel
}
