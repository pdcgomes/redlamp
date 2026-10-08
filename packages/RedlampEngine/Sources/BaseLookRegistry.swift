import Foundation
import Metal
import RedlampEngineAPI

/// Base Looks the engine can render, and their tables as GPU textures.
///
/// Registration can happen on any thread while renders read from the render queue; all
/// state is behind `lock`. A table is uploaded when a render first uses it, outside the
/// lock, and cached by content hash, so a look registered twice is uploaded once.
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
    /// Signalled when a batch of looks has been registered.
    private let lock = NSCondition()
    private var definitions: [Key: BaseLookDefinition] = [:]
    private var textures: [String: any MTLTexture] = [:]
    /// Least recently used first.
    private var textureOrder: [String] = []
    private var registrations: UInt64 = 0
    /// Batches still being decoded; renders of looks not yet registered wait for them.
    private var pendingBatches = 0
    /// Bound when an edit has no table, because Metal needs a texture in every slot.
    let identity: any MTLTexture

    /// Moves whenever a registration changes a look, so renders kept for reuse can tell a
    /// look may have changed.
    var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return registrations
    }

    /// Tables on the GPU now.
    var uploadedTables: Int {
        lock.lock()
        defer { lock.unlock() }
        return textures.count
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
        store(look)
    }

    /// Registers what `load` returns, decoding on a background queue.
    func register(_ load: @escaping @Sendable () -> [BaseLookDefinition]) {
        lock.lock()
        pendingBatches += 1
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let looks = load()
            lock.lock()
            defer { lock.unlock() }
            for look in looks {
                store(look)
            }
            pendingBatches -= 1
            lock.broadcast()
        }
    }

    /// Call with `lock` held.
    private func store(_ look: BaseLookDefinition) {
        let key = Key(id: look.id, version: look.version)
        if let current = definitions[key], current.name == look.name, current.parameters == look.parameters,
           current.table?.contentHash == look.table?.contentHash {
            return
        }
        definitions[key] = look
        registrations &+= 1
    }

    func canRender(_ reference: BaseLookReference) -> Bool {
        if BuiltInBaseLook(reference: reference) != nil {
            return true
        }
        lock.lock()
        defer { lock.unlock() }
        guard let look = definitions[Key(id: reference.id, version: reference.version)] else { return false }
        return look.table?.contentHash == reference.contentHash
    }

    /// The look to render for `reference`, at full strength; callers scale by amount.
    func resolve(_ reference: BaseLookReference) -> Resolved {
        if let builtIn = BuiltInBaseLook(reference: reference) {
            return Resolved(parameters: builtIn.parameters, table: nil, tableSize: 0, isAvailable: true)
        }
        let key = Key(id: reference.id, version: reference.version)
        lock.lock()
        while definitions[key] == nil, pendingBatches > 0 {
            lock.wait()
        }
        let look = definitions[key]
        let cached = look?.table.flatMap { cachedTexture($0.contentHash) }
        lock.unlock()
        guard let look else {
            return Resolved(parameters: .identity, table: nil, tableSize: 0, isAvailable: false)
        }
        guard let hash = reference.contentHash else {
            return Resolved(parameters: look.parameters, table: nil, tableSize: 0, isAvailable: look.table == nil)
        }
        guard let table = look.table, table.contentHash == hash, let texture = cached ?? upload(table) else {
            return Resolved(parameters: look.parameters, table: nil, tableSize: 0, isAvailable: false)
        }
        return Resolved(
            parameters: look.parameters, table: texture, tableSize: table.size, isAvailable: true,
            tableSpace: table.space,
        )
    }

    /// The cached texture for `hash`, marked as just used. Call with `lock` held.
    private func cachedTexture(_ hash: String) -> (any MTLTexture)? {
        guard let texture = textures[hash] else { return nil }
        textureOrder.removeAll { $0 == hash }
        textureOrder.append(hash)
        return texture
    }

    /// Uploads `table` without holding `lock`, then caches it; a texture another render
    /// cached meanwhile wins.
    private func upload(_ table: LookTable) -> (any MTLTexture)? {
        guard let texture = Self.makeTexture(table, device: device) else { return nil }
        let hash = table.contentHash
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedTexture(hash) {
            return cached
        }
        textures[hash] = texture
        textureOrder.append(hash)
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
