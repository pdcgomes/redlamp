#if DEBUG || REDLAMP_PROFILING
    import Foundation
    import RedlampEngine
    import RedlampServices

    /// `--decode-check <file>`: decodes the file through the bundled decode service and in this
    /// process, prints whether they agree and exits, so the service can be checked from a shell.
    enum DebugDecodeCheck {
        static func runIfRequested() {
            let arguments = LaunchArguments.all
            if let index = arguments.firstIndex(of: "--stack-check") {
                checkStack(arguments[(index + 1)...].prefix { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) })
            }
            guard let index = arguments.firstIndex(of: "--decode-check"), index + 1 < arguments.count else { return }
            let url = URL(fileURLWithPath: arguments[index + 1])
            // The decode service is never waited on from the main thread.
            Task.detached {
                do {
                    let started = Date()
                    let image = try DecodeServiceClient().decode(url)
                    let elapsed = Date().timeIntervalSince(started)
                    let localStarted = Date()
                    let local = try ImageDecoder.decode(url)
                    let localElapsed = Date().timeIntervalSince(localStarted)
                    let differences = [
                        image.samples == local.samples ? nil : "samples",
                        image.info == local.info ? nil : "info",
                        image.blackLevels == local.blackLevels && image.whiteLevel == local.whiteLevel ? nil : "levels",
                        image.noiseProfile == local.noiseProfile && image.gainMaps == local.gainMaps ? nil : "DNG tags",
                        image.dngColor == local.dngColor && image.banding == local.banding ? nil : "colour or banding",
                    ].compactMap(\.self)
                    print(String(
                        format: "decoded %@: %dx%d in %.2f s (%.2f s in-process), identical to in-process: %@",
                        url.lastPathComponent, image.width, image.height, elapsed, localElapsed,
                        differences.isEmpty ? "yes" : "NO (\(differences.joined(separator: ", ")))",
                    ))
                    exit(differences.isEmpty ? 0 : 2)
                } catch {
                    print("decode failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            DispatchSemaphore(value: 0).wait()
        }

        /// `--stack-check <frame>…`: merges the frames through the decode service and in this
        /// process, alternating three times, prints each merge's time and exits.
        private static func checkStack(_ frames: [URL]) {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let engines: [(String, RedlampEngine)] = try [
                        ("service", RedlampEngine(decoder: DecodeServiceClient())),
                        ("in-process", RedlampEngine(decoder: InProcessDecoder())),
                    ]
                    for round in 1 ... 3 {
                        for (name, engine) in engines {
                            let preview = try await engine.renderFocusStack(frames, maxLongEdge: 512)
                            let failed = preview.report.failedFrames?.map(\.index) ?? []
                            print(String(
                                format: "round %d %@: %.2f s total, %.2f s decoding, failed frames %@", round, name,
                                preview.report.timings["total"] ?? 0, preview.report.timings["decode"] ?? 0,
                                "\(failed)",
                            ))
                        }
                    }
                } catch {
                    print("stack failed: \(error.localizedDescription)")
                }
                done.signal()
            }
            done.wait()
            exit(0)
        }
    }
#endif
