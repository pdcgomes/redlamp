import Metal
import RedlampEngineAPI
import RedlampMasking

/// A guided filter's coefficients on a small map (`GuidedFilter.coefficients`), which the develop
/// kernel upsamples and applies to each pixel's own guide value, `a * guide + b`, so the result's
/// edges are as sharp as the photo's (K. He & J. Sun, "Fast guided filter", 2015). The tone base
/// (`ToneBase`) guides log luminance by itself; the refined haze map (`Haze`) guides the dark
/// channel by the photo's brightness.
struct GuidedMap {
    let width: Int
    let height: Int
    /// Per texel: the output is `a * guide + b`.
    let a: [Float]
    let b: [Float]

    init(input: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float) {
        self.width = width
        self.height = height
        (a, b) = GuidedFilter.coefficients(
            input, guide: guide, width: width, height: height, radius: radius, epsilon: epsilon,
        )
    }

    /// As a texture (a, b) for the develop kernel, or (a, b, third) with a third map of the size.
    func texture(device: any MTLDevice, third: [Float]? = nil) throws -> any MTLTexture {
        let channels = third == nil ? 2 : 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: third == nil ? .rg32Float : .rgba32Float, width: width, height: height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        var texels = [Float](repeating: 0, count: a.count * channels)
        for index in a.indices {
            texels[index * channels] = a[index]
            texels[index * channels + 1] = b[index]
            if let third {
                texels[index * channels + 2] = third[index]
            }
        }
        texels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: width * channels * 4,
            )
        }
        return texture
    }
}
