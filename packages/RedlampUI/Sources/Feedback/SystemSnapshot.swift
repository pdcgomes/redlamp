import AppKit
import Foundation
import Metal
import RedlampEngineAPI

/// The build and the Mac a report comes from.
public struct SystemSnapshot: Codable, Sendable, Hashable {
    public var appVersion: String
    public var build: String
    /// The commit a release was built from; `nil` in a build from source.
    public var commit: String?
    /// Release, Debug or Profiling.
    public var configuration: String
    /// "26.1 (25B78)".
    public var macOS: String
    /// "Mac16,7".
    public var model: String
    public var chip: String
    public var cores: String
    public var memory: String
    public var gpu: String
    public var displays: [String]
    public var thermalState: String
    public var lowPowerMode: Bool
    public var locale: String
    /// Downloadable models and whether each is on this Mac.
    public var models: [String]

    /// "0.2.1-prealpha (412, 1a2b3c4d5e6f)".
    public var version: String {
        "\(appVersion) (\([build, commit].compactMap(\.self).joined(separator: ", ")))"
    }

    /// The rows of the report's System table.
    public var rows: [(String, String)] {
        var rows = [
            ("Redlamp", "\(version), \(configuration)"),
            ("macOS", macOS),
            ("Mac", "\(model), \(chip), \(cores)"),
            ("Memory", memory),
            ("GPU", gpu),
        ]
        rows += displays.enumerated().map { ("Display \($0.offset + 1)", $0.element) }
        rows += [
            ("Thermal state", thermalState + (lowPowerMode ? ", Low Power Mode" : "")),
            ("Locale", locale),
        ]
        if !models.isEmpty {
            rows.append(("Models", models.joined(separator: "; ")))
        }
        return rows
    }

    @MainActor
    public static func capture(models: [ModelInfo], bundle: Bundle = .main) -> SystemSnapshot {
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        let osBuild = sysctl("kern.osversion").map { " (\($0))" } ?? ""
        let performance = sysctlInt("hw.perflevel0.physicalcpu")
        let efficiency = sysctlInt("hw.perflevel1.physicalcpu")
        let cores = if let performance, let efficiency {
            "\(performance) performance and \(efficiency) efficiency cores"
        } else {
            "\(info.processorCount) cores"
        }
        let device = MTLCreateSystemDefaultDevice()
        let gpu = device.map { "\($0.name), \(gigabytes($0.recommendedMaxWorkingSetSize)) working set" } ?? "No Metal device"
        let commit = (bundle.object(forInfoDictionaryKey: "RedlampCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SystemSnapshot(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            commit: commit,
            configuration: configuration,
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\(osBuild)",
            model: sysctl("hw.model") ?? "unknown",
            chip: sysctl("machdep.cpu.brand_string") ?? "unknown",
            cores: cores,
            memory: gigabytes(info.physicalMemory),
            gpu: gpu,
            displays: NSScreen.screens.map(describe),
            thermalState: ActivityRecorder.name(info.thermalState),
            lowPowerMode: info.isLowPowerModeEnabled,
            locale: Locale.current.identifier,
            models: models.map { "\($0.name) (\($0.id)): \(state($0.state))" },
        )
    }

    private static var configuration: String {
        #if DEBUG
            "Debug"
        #elseif REDLAMP_PROFILING
            "Profiling"
        #else
            "Release"
        #endif
    }

    @MainActor
    private static func describe(_ screen: NSScreen) -> String {
        let size = screen.frame.size
        var parts = ["\(Int(size.width)) × \(Int(size.height)) pt at \(Int(screen.backingScaleFactor))x"]
        if let space = screen.colorSpace?.localizedName {
            parts.append(space)
        }
        let headroom = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        parts.append(headroom > 1 ? String(format: "HDR up to %.0fx", headroom) : "SDR")
        return parts.joined(separator: ", ")
    }

    private static func state(_ state: ModelInfo.State) -> String {
        switch state {
        case .notDownloaded: "not downloaded"
        case let .downloading(progress): "downloading, \(Int(progress * 100))%"
        case .ready: "ready"
        }
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return value >= 10 ? "\(Int(value.rounded())) GB" : String(format: "%.1f GB", value)
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
