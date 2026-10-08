import Foundation
import Metal
import RedlampEngineAPI

/// Base Looks the engine can render, and their tables as GPU textures.
///
/// Registration can happen on any thread while renders read from the render queue; all
/// state is behind `lock`. A look registered from a `BaseLookSource` is read when a render
/// first uses it, and its table uploaded then, both outside the lock; tables are cached by
/// content hash, so a look registered twice is uploaded once.
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

    /// A registered look: what edits pin it by, and the look itself once read.
    private struct Entry {
        var name: String
        var parameters: BaseLookParameters
        var contentHash: String?
        var look: BaseLookDefinition?
        var load: (@Sendable () -> BaseLookDefinition?)?
        /// Its loader failed: edits that use it show it missing, and render without it.
        var isUnreadable = false
        /// Tells the entry a read started from apart from one registered meanwhile.
        var serial: UInt64 = 0

        init(_ look: BaseLookDefinition) {
            name = look.name
            parameters = look.parameters
            contentHash = look.table?.contentHash
            self.look = look
        }

        init(_ source: BaseLookSource) {
            name = source.reference.name
            parameters = source.parameters
            contentHash = source.reference.contentHash
            load = source.load
        }

        func describesSameLook(as other: Entry) -> Bool {
            name == other.name && parameters == other.parameters && contentHash == other.contentHash
        }
    }

    /// Tables stay on the GPU up to this count (32 tables of 33³ are about 9 MB); evicted
    /// ones are uploaded again from their definition when next used.
    static let textureLimit = 32

    private let device: any MTLDevice
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var serials: UInt64 = 0
    private var textures: [String: any MTLTexture] = [:]
    /// Least recently used first.
    private var textureOrder: [String] = []
    private var registrations: UInt64 = 0
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
        store(Entry(look), key: Key(id: look.id, version: look.version))
    }

    func register(_ looks: [BaseLookSource]) {
        lock.lock()
        defer { lock.unlock() }
        for look in looks {
            store(Entry(look), key: Key(id: look.reference.id, version: look.reference.version))
        }
    }

    /// Call with `lock` held.
    private func store(_ entry: Entry, key: Key) {
        if let current = entries[key], !current.isUnreadable, current.describesSameLook(as: entry) {
            if current.look == nil, entry.look != nil {
                entries[key]?.look = entry.look
            }
            return
        }
        var entry = entry
        serials &+= 1
        entry.serial = serials
        entries[key] = entry
        registrations &+= 1
    }

    func canRender(_ reference: BaseLookReference) -> Bool {
        if BuiltInBaseLook(reference: reference) != nil {
            return true
        }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[Key(id: reference.id, version: reference.version)] else { return false }
        return !entry.isUnreadable && entry.contentHash == reference.contentHash
    }

    /// The look to render for `reference`, at full strength; callers scale by amount. Reads
    /// the look first if it hasn't been yet.
    func resolve(_ reference: BaseLookReference) -> Resolved {
        if let builtIn = BuiltInBaseLook(reference: reference) {
            return Resolved(parameters: builtIn.parameters, table: nil, tableSize: 0, isAvailable: true)
        }
        let key = Key(id: reference.id, version: reference.version)
        lock.lock()
        let entry = entries[key]
        lock.unlock()
        let missing = Resolved(parameters: .identity, table: nil, tableSize: 0, isAvailable: false)
        guard let entry, !entry.isUnreadable else {
            return missing
        }
        guard let hash = reference.contentHash else {
            return Resolved(
                parameters: entry.parameters,
                table: nil,
                tableSize: 0,
                isAvailable: entry.contentHash == nil,
            )
        }
        guard entry.contentHash == hash else {
            return Resolved(parameters: entry.parameters, table: nil, tableSize: 0, isAvailable: false)
        }
        guard let look = entry.look ?? read(entry, key: key) else {
            return missing
        }
        guard let table = look.table, table.contentHash == hash else {
            return Resolved(parameters: entry.parameters, table: nil, tableSize: 0, isAvailable: false)
        }
        lock.lock()
        let cached = cachedTexture(hash)
        lock.unlock()
        guard let texture = cached ?? upload(table) else {
            return Resolved(parameters: look.parameters, table: nil, tableSize: 0, isAvailable: false)
        }
        return Resolved(
            parameters: look.parameters, table: texture, tableSize: table.size, isAvailable: true,
            tableSpace: table.space,
        )
    }

    /// Reads `entry`'s look without holding `lock`, keeping it unless the look was registered
    /// again meanwhile. A look that can't be read is marked unreadable, moving the generation
    /// once so edits that use it show it missing.
    private func read(_ entry: Entry, key: Key) -> BaseLookDefinition? {
        let look = entry.load?()
        lock.lock()
        defer { lock.unlock() }
        guard entries[key]?.serial == entry.serial, entries[key]?.isUnreadable == false else { return look }
        if let look {
            entries[key]?.look = look
        } else {
            entries[key]?.isUnreadable = true
            registrations &+= 1
        }
        entries[key]?.load = nil
        return look
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
