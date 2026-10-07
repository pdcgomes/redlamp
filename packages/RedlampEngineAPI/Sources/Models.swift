import Foundation

/// A model the engine can download for a feature (Objects masks, Depth Range), as Settings and
/// the first-use prompt show it.
public struct ModelInfo: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case notDownloaded
        case downloading(Double)
        case ready
    }

    public var id: String
    public var name: String
    public var purpose: String
    public var downloadBytes: Int
    public var state: State
    /// Its training data's terms don't allow shipping it (see `decision`).
    public var isEvaluationOnly: Bool
    /// Cleared for everyone; otherwise offered only while evaluating (Settings › Models).
    public var isCleared: Bool
    /// Downloadable; otherwise only usable where it was built.
    public var isPublished: Bool
    public var decision: String?
    /// Its weights' licence ("Apache-2.0", "SAM License"), and where to read it when it comes with
    /// the download.
    public var licence: String?
    public var licenceURL: URL?
    /// The datasets its weights were trained on, as its manifest names them.
    public var trainingData: [String]
    /// The least memory it runs in, in bytes, and whether this Mac has that much.
    public var minimumMemory: Int?
    public var fitsThisMac: Bool
    /// The least memory it has been tested on, in bytes, and whether this Mac has that much.
    public var testedMemory: Int?
    public var testedOnThisMac: Bool

    public init(
        id: String, name: String, purpose: String, downloadBytes: Int, state: State, isEvaluationOnly: Bool = false,
        isCleared: Bool = true, isPublished: Bool = true, decision: String? = nil, licence: String? = nil,
        licenceURL: URL? = nil, trainingData: [String] = [], minimumMemory: Int? = nil, fitsThisMac: Bool = true,
        testedMemory: Int? = nil, testedOnThisMac: Bool = true,
    ) {
        self.trainingData = trainingData
        self.minimumMemory = minimumMemory
        self.fitsThisMac = fitsThisMac
        self.testedMemory = testedMemory
        self.testedOnThisMac = testedOnThisMac
        self.isCleared = isCleared
        self.isPublished = isPublished
        self.id = id
        self.name = name
        self.purpose = purpose
        self.downloadBytes = downloadBytes
        self.state = state
        self.isEvaluationOnly = isEvaluationOnly
        self.decision = decision
        self.licence = licence
        self.licenceURL = licenceURL
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(downloadBytes), countStyle: .file)
    }

    /// "Needs 16 GB of memory; this Mac has 8 GB", when this Mac has too little.
    public var memoryNote: String? {
        guard !fitsThisMac, let minimumMemory else { return nil }
        return "Needs \(Self.memory(minimumMemory)) of memory; this Mac has \(Self.memory(Self.thisMac))."
    }

    /// "Not tested on Macs with less than 16 GB of memory; it may be slow or not work on this one
    /// (8 GB).", when this Mac has less memory than it has been tested on.
    public var untestedNote: String? {
        guard !testedOnThisMac, let testedMemory else { return nil }
        return "Not tested on Macs with less than \(Self.memory(testedMemory)) of memory; it may be slow or not work on this one (\(Self.memory(Self.thisMac)))."
    }

    /// "`feature` hasn't been tested on Macs with less than 16 GB of memory, and may be slow or not
    /// work on this one (8 GB).", when this Mac has less memory than the model has been tested on.
    public func untestedCaution(for feature: String) -> String? {
        guard !testedOnThisMac, let testedMemory else { return nil }
        return "\(feature) hasn't been tested on Macs with less than \(Self.memory(testedMemory)) of memory, and may be slow or not work on this one (\(Self.memory(Self.thisMac)))."
    }

    private static var thisMac: Int {
        Int(ProcessInfo.processInfo.physicalMemory)
    }

    private static func memory(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
