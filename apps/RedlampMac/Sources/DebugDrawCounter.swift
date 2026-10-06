#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Foundation
    import RedlampDesign

    /// `--count-graph-draws [--count-graph-draws-log <path>]`: writes, once a second, how often the
    /// histogram and the Tone Curve drew and how long their drawing kept the main thread, beside
    /// the main thread's longest run-loop iteration; and, as they happen, each window's move to
    /// another screen and each change of the graphs' size or backing scale. For finding what puts
    /// the graphs into drawing for about 190 ms per commit (RESP-11). The log goes to
    /// /tmp/redlamp-draw-counter/ unless a path is given.
    @MainActor
    enum DebugDrawCounter {
        private struct Tally {
            var draws = 0
            var milliseconds = 0.0
            var longest = 0.0
        }

        /// The graphs counted by name; every other layer-drawn view is counted together.
        private static let graphs: Set<String> = ["HistogramGraphView", "CurveGraphView", "SplitHandlesView"]
        private static let others = "other layer-drawn views"

        private static var tallies: [String: Tally] = [:]
        private static var log: FileHandle?
        private static let monitor = MainThreadMonitor()
        private static let started = CFAbsoluteTimeGetCurrent()
        private static var observers: [NSObjectProtocol] = []

        static func startIfRequested() {
            let arguments = LaunchArguments.all
            guard arguments.contains("--count-graph-draws") else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: Date())
            let path = arguments.firstIndex(of: "--count-graph-draws-log").flatMap {
                $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
            } ?? "/tmp/redlamp-draw-counter/draws-\(stamp).log"
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            )
            FileManager.default.createFile(atPath: path, contents: nil)
            log = FileHandle(forWritingAtPath: path)
            let info = Bundle.main.infoDictionary ?? [:]
            write(
                "Redlamp draw counter: \(Bundle.main.bundleIdentifier ?? "?") \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")), log \(path)",
            )
            for screen in NSScreen.screens {
                write(
                    "screen \(describe(screen)), frame \(Int(screen.frame.minX)),\(Int(screen.frame.minY)) \(Int(screen.frame.width))×\(Int(screen.frame.height))",
                )
            }

            LayerDrawnView.drawObserver = { view, event in
                record(view, event)
            }
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: nil,
                queue: .main,
            ) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    write("window \(name(of: window)) moved to screen \(window?.screen.map(describe) ?? "?")")
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didChangeBackingPropertiesNotification, object: nil, queue: .main,
            ) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    write("window \(name(of: window)) backing scale now \(window?.backingScaleFactor ?? 0)")
                }
            })
            observers.append(center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main,
            ) { _ in
                MainActor.assumeIsolated {
                    write("screens changed: \(NSScreen.screens.map(describe).joined(separator: "; "))")
                }
            })
            monitor.start()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { flush() }
            }
        }

        private static func record(_ view: LayerDrawnView, _ event: LayerDrawnView.DrawEvent) {
            let kind = String(describing: type(of: view))
            let graph = graphs.contains(kind)
            switch event {
            case let .drew(milliseconds):
                let key = graph ? kind : others
                var tally = tallies[key] ?? Tally()
                tally.draws += 1
                tally.milliseconds += milliseconds
                tally.longest = max(tally.longest, milliseconds)
                tallies[key] = tally
            case let .laidOut(size, scale) where graph:
                write(
                    "\(kind) laid out at \(Int(size.width))×\(Int(size.height)) pt, scale \(scale), in \(name(of: view.window))",
                )
            case let .backingChanged(scale) where graph:
                write(
                    "\(kind) backing scale now \(scale), in \(name(of: view.window)) on \(view.window?.screen.map(describe) ?? "?")",
                )
            default:
                break
            }
        }

        /// One line for the second just past.
        private static func flush() {
            monitor.stop()
            let main = monitor.summary(seconds: 1)
            monitor.start()
            var parts = [main.map {
                String(
                    format: "main thread busy %.0f%%, longest iteration %.1f ms, >16.7 ms: %d",
                    $0.busy * 100, $0.max, $0.overTwoFrames,
                )
            } ?? "main thread idle"]
            for kind in graphs.sorted() + [others] {
                guard let tally = tallies[kind] else { continue }
                parts.append(String(
                    format: "%@ %d draws, %.1f ms (longest %.1f ms)",
                    kind, tally.draws, tally.milliseconds, tally.longest,
                ))
            }
            tallies = [:]
            write(String(format: "t=%.0fs ", CFAbsoluteTimeGetCurrent() - started) + parts.joined(separator: " | "))
        }

        private static func describe(_ screen: NSScreen) -> String {
            "\(screen.localizedName) (scale \(screen.backingScaleFactor))"
        }

        private static func name(of window: NSWindow?) -> String {
            guard let window else { return "(none)" }
            return "'\(window.title.isEmpty ? window.identifier?.rawValue ?? "untitled" : window.title)'"
        }

        private static func write(_ line: String) {
            let stamped = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)\n"
            log?.write(Data(stamped.utf8))
        }
    }
#endif
