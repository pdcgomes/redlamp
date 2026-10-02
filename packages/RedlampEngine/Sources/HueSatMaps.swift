import Metal
import RedlampColor
import RedlampServices
import simd

/// A camera profile's HueSatMaps on the GPU, one per calibration illuminant, blended in the
/// develop kernel by the white balance's colour temperature as the matrices are (process 4).
struct HueSatMaps {
    let cool: any MTLTexture
    /// The same texture as `cool` when the profile has one map.
    let warm: any MTLTexture
    let srgbValues: Bool

    /// Linear Rec.2020 (D65) to linear ProPhoto (D50), the space the maps work in.
    static let workingToProPhoto = (RGBPrimaries.proPhoto.fromXYZ * DNGColorCalibration.bradfordD50ToD65.inverse
        * ColorMatrices.rec2020ToXYZ).floatMatrix

    /// Nil without maps, or when the two maps differ in size or encoding (the specification
    /// requires them to match).
    init?(profile: DNGProfile?, device: any MTLDevice) {
        guard let maps = profile?.hueSatMaps, let first = maps.first,
              maps.allSatisfy({
                  $0.hues == first.hues && $0.saturations == first.saturations && $0.values == first.values
                      && $0.srgbValues == first.srgbValues
              }),
              let cool = Self.texture(first, device: device)
        else { return nil }
        self.cool = cool
        if maps.count > 1 {
            guard let warm = Self.texture(maps[1], device: device) else { return nil }
            self.warm = warm
        } else {
            warm = cool
        }
        srgbValues = first.srgbValues
    }

    /// Saturation across, hue down, value in depth: the file's order, so entries copy straight in.
    private static func texture(_ map: DNGProfile.HSVMap, device: any MTLDevice) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = map.saturations
        descriptor.height = map.hues
        descriptor.depth = map.values
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let count = map.saturations * map.hues * map.values
        var rgba = [Float](repeating: 0, count: count * 4)
        for i in 0 ..< count {
            rgba[i * 4] = map.entries[i * 3]
            rgba[i * 4 + 1] = map.entries[i * 3 + 1]
            rgba[i * 4 + 2] = map.entries[i * 3 + 2]
        }
        let rowBytes = map.saturations * 4 * MemoryLayout<Float>.stride
        rgba.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, map.saturations, map.hues, map.values),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: rowBytes, bytesPerImage: rowBytes * map.hues,
            )
        }
        return texture
    }
}
