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

    public init(
        id: String, name: String, purpose: String, downloadBytes: Int, state: State, isEvaluationOnly: Bool = false,
        isCleared: Bool = true, isPublished: Bool = true, decision: String? = nil, licence: String? = nil,
        licenceURL: URL? = nil,
    ) {
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
}
