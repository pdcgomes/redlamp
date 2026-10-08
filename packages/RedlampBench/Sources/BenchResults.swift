import Foundation

/// `results.json`: what came back for a bench folder, written on the phone.
public struct BenchResults: Codable, Sendable, Hashable {
    public static let fileName = "results.json"
    public static let folder = "results"

    public var results: [BenchResult]
    /// Answers by question ID.
    public var answers: [String: String]
    public var note: String?
    /// When the owner marked a manual task done, or when the phone saw it complete.
    public var completed: Date?
    /// The phone that sent it, as its owner named it.
    public var device: String?

    public init(
        results: [BenchResult] = [],
        answers: [String: String] = [:],
        note: String? = nil,
        completed: Date? = nil,
        device: String? = nil,
    ) {
        self.results = results
        self.answers = answers
        self.note = note
        self.completed = completed
        self.device = device
    }

    /// The newest result paired with an asset.
    public func current(for asset: String) -> BenchResult? {
        results.last { $0.asset == asset }
    }

    public var unpaired: [BenchResult] {
        results.filter { $0.asset == nil }
    }
}

public struct BenchResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Relative to the folder, under `results/`.
    public var file: String
    /// The name the file had when it was shared.
    public var originalName: String
    public var sha256: String
    public var bytes: Int
    public var received: Date
    public var asset: String?
    public var pairedBy: BenchManifest.Pairing?
    /// Similarity's score (−1…1) when it paired by similarity.
    public var score: Double?

    public init(
        id: String = UUID().uuidString.lowercased(),
        file: String,
        originalName: String,
        sha256: String,
        bytes: Int,
        received: Date = Date(),
        asset: String? = nil,
        pairedBy: BenchManifest.Pairing? = nil,
        score: Double? = nil,
    ) {
        self.id = id
        self.file = file
        self.originalName = originalName
        self.sha256 = sha256
        self.bytes = bytes
        self.received = received
        self.asset = asset
        self.pairedBy = pairedBy
        self.score = score
    }
}
