import Foundation

/// Model outputs worth keeping between sessions (SAM's image embedding is about 8 MB a photo and
/// takes ~60 ms to recompute), in the purgeable Caches directory, never in the sidecar.
/// Keyed by the analysis render's hash and the model version; the least recently used go first
/// once the cache passes its budget.
public actor EmbeddingCache {
    public static let shared = EmbeddingCache()

    public let root: URL
    public let budget: Int
    private var memory: (key: String, data: Data)?

    public init(root: URL? = nil, budget: Int = 1 << 30) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.redlamp/Embeddings")
        self.budget = budget
    }

    /// The entry kept in memory, and its size.
    public var inMemory: (key: String, bytes: Int)? {
        memory.map { ($0.key, $0.data.count) }
    }

    public static func key(model: ModelManifest, analysisHash: String) -> String {
        "\(model.id)-v\(model.version)-\(analysisHash)"
    }

    public func data(for key: String) -> Data? {
        if let memory, memory.key == key {
            return memory.data
        }
        let url = root.appending(path: key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        memory = (key, data)
        return data
    }

    public func store(_ data: Data, for key: String) {
        memory = (key, data)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: root.appending(path: key), options: .atomic)
        trim()
    }

    /// Removes the least recently used entries until the cache fits its budget.
    func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys),
        ) else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > budget {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
