import Foundation

/// A named set of export settings.
public struct ExportPreset: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var settings: ExportSettings

    public init(id: UUID = UUID(), name: String, settings: ExportSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    public var isBuiltIn: Bool {
        Self.builtIns.contains { $0.id == id }
    }

    /// Starting points that ship with Redlamp; they can't be changed or deleted.
    public static let builtIns: [ExportPreset] = {
        var full = ExportSettings()
        full.quality = 90

        var web = ExportSettings()
        web.quality = 85
        web.sizing = ExportSizing(mode: .longEdge)
        web.sizing.longEdge = 2048
        web.metadata = .allExceptLocation

        var email = ExportSettings()
        email.sizing = ExportSizing(mode: .longEdge)
        email.sizing.longEdge = 1600
        email.limitsFileSize = true
        email.fileSizeLimitKB = 500
        email.metadata = .allExceptLocation

        var print = ExportSettings()
        print.setFormat(.tiff)
        print.bitDepth = 16
        print.tiffCompression = .zip
        print.colorSpace = .displayP3

        return [
            ExportPreset(id: builtInID(1), name: "Full Size JPEG", settings: full),
            ExportPreset(id: builtInID(2), name: "Web, 2048 px", settings: web),
            ExportPreset(id: builtInID(3), name: "Email, under 500 KB", settings: email),
            ExportPreset(id: builtInID(4), name: "Print, 16-bit TIFF", settings: print),
        ]
    }()

    private static func builtInID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
    }
}
