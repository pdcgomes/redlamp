#if DEBUG || REDLAMP_PROFILING
    import Foundation
    import RedlampServices

    /// `--decode-check <file>`: decodes the file through the bundled decode service and in this
    /// process, prints whether they agree and exits, so the service can be checked from a shell.
    enum DebugDecodeCheck {
        static func runIfRequested() {
            let arguments = LaunchArguments.all
            guard let index = arguments.firstIndex(of: "--decode-check"), index + 1 < arguments.count else { return }
            let url = URL(fileURLWithPath: arguments[index + 1])
            do {
                let started = Date()
                let image = try DecodeServiceClient().decode(url)
                let elapsed = Date().timeIntervalSince(started)
                let local = try ImageDecoder.decode(url)
                let differences = [
                    image.samples == local.samples ? nil : "samples",
                    image.info == local.info ? nil : "info",
                    image.blackLevels == local.blackLevels && image.whiteLevel == local.whiteLevel ? nil : "levels",
                    image.noiseProfile == local.noiseProfile && image.gainMaps == local.gainMaps ? nil : "DNG tags",
                    image.dngColor == local.dngColor && image.banding == local.banding ? nil : "colour or banding",
                ].compactMap(\.self)
                print(String(
                    format: "decoded %@: %dx%d in %.2f s, identical to in-process: %@",
                    url.lastPathComponent, image.width, image.height, elapsed,
                    differences.isEmpty ? "yes" : "NO (\(differences.joined(separator: ", ")))",
                ))
                exit(differences.isEmpty ? 0 : 2)
            } catch {
                print("decode failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
#endif
