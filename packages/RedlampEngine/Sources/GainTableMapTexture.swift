import Metal
import RedlampServices

/// A DNG ProfileGainTableMap on the GPU (process 5, with the photo's embedded look): table entries across, the grid's
/// columns
/// down and its rows in depth, so one trilinear sample is the specification's bilinear blend of
/// four tables and linear lookup within them.
struct GainTableMapTexture {
    let texture: any MTLTexture
    let map: DNGProfile.GainTableMap

    init?(_ map: DNGProfile.GainTableMap?, device: any MTLDevice) {
        guard let map else { return nil }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = map.points
        descriptor.height = map.columns
        descriptor.depth = map.rows
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let rowBytes = map.points * MemoryLayout<Float>.stride
        map.gains.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, map.points, map.columns, map.rows), mipmapLevel: 0, slice: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: rowBytes, bytesPerImage: rowBytes * map.columns,
            )
        }
        self.texture = texture
        self.map = map
    }
}
