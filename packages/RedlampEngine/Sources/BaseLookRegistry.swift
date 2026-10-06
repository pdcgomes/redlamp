import Foundation
import Metal
import RedlampEngineAPI

/// Base Looks the engine can render, and their tables as GPU textures.
///
/// Registration can happen on any thread while renders read from the render queue; all
/// state is behind `lock`. Tables are cached by content hash, so a look registered twice
/// is uploaded once.
final class BaseLookRegistry: @unchecked Sendable {
    struct Resolved {
        var parameters: BaseLookParameters
        var table: (any MTLTexture)?
        var tableSize: Int
        /// False when the edit's look isn't registered and renders without it.
        var isAvailable: Bool
        var tableSpace: LookTableSpace = .displayRec2020
    }

    private struct Key: Hashable {
        var id: String
        var version: Int
    }

    /// Tables stay on the GPU up to this count (32 tables of 33³ are about 9 MB); evicted
    /// ones are uploaded again from their definition when next used.
    static let textureLimit = 32

    private let device: any MTLDevice
    private let lock = NSLock()
    private var definitions: [Key: BaseLookDefinition] = [:]
    private var textures: [String: any MTLTexture] = [:]
    /// Least recently used first.
    private var textureOrder: [String] = []
    private var registrations: UInt64 = 0
    /// Bound when an edit has no table, because Metal needs a texture in every slot.
    let identity: any MTLTexture

    /// Moves on every registration, so renders kept for reuse can tell a look may have changed.
    var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return registrations
    }

    init(device: any MTLDevice) throws {
        self.device = device
        guard let identity = Self.makeTexture(LookTable.identity(size: 2), device: device) else {
            throw EngineError.gpuUnavailable
        }
        self.identity = identity
    }

    func register(_ look: BaseLookDefinition) {
        lock.lock()
        defer { lock.unlock() }
        definitions[Key(id: look.id, version: look.version)] = look
        registrations &+= 1
        if let table = look.table {
            _ = texture(for: table)
        }
    }

    func canRender(_ reference: BaseLookReference) -> Bool {
        resolve(reference).isAvailable
    }

    /// The look to render for `reference`, at full strength; callers scale by amount.
    func resolve(_ reference: BaseLookReference) -> Resolved {
        if let builtIn = BuiltInBaseLook(reference: reference) {
            return Resolved(parameters: builtIn.parameters, table: nil, tableSize: 0, isAvailable: true)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let look = definitions[Key(id: reference.id, version: reference.version)] else {
            return Resolved(parameters: .identity, table: nil, tableSize: 0, isAvailable: false)
        }
        guard let hash = reference.contentHash else {
            return Resolved(parameters: look.parameters, table: nil, tableSize: 0, isAvailable: look.table == nil)
        }
        guard let table = look.table, table.contentHash == hash, let texture = texture(for: table) else {
            return Resolved(parameters: look.parameters, table: nil, tableSize: 0, isAvailable: false)
        }
        return Resolved(
            parameters: look.parameters, table: texture, tableSize: table.size, isAvailable: true,
            tableSpace: table.space,
        )
    }

    /// The table's texture, uploading it if needed. Call with `lock` held.
    private func texture(for table: LookTable) -> (any MTLTexture)? {
        let hash = table.contentHash
        textureOrder.removeAll { $0 == hash }
        textureOrder.append(hash)
        if let cached = textures[hash] {
            return cached
        }
        guard let texture = Self.makeTexture(table, device: device) else { return nil }
        textures[hash] = texture
        while textureOrder.count > Self.textureLimit {
            textures.removeValue(forKey: textureOrder.removeFirst())
        }
        return texture
    }

    private static func makeTexture(_ table: LookTable, device: any MTLDevice) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = table.size
        descriptor.height = table.size
        descriptor.depth = table.size
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var rgba = [Float16](repeating: 1, count: table.size * table.size * table.size * 4)
        for i in 0 ..< table.size * table.size * table.size {
            rgba[i * 4] = table.values[i * 3]
            rgba[i * 4 + 1] = table.values[i * 3 + 1]
            rgba[i * 4 + 2] = table.values[i * 3 + 2]
        }
        let rowBytes = table.size * 4 * MemoryLayout<Float16>.stride
        rgba.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, table.size, table.size, table.size),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: rowBytes, bytesPerImage: rowBytes * table.size,
            )
        }
        return texture
    }
}
