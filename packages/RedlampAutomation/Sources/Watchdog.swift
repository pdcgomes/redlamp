#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Darwin
    import RedlampCanvas
    @_spi(Harness) import RedlampUI
    import Synchronization

    /// Notices a main thread that stops turning its run loop: it schedules a ping every 100 ms
    /// and, when one waits more than `limit`, records the stall with the main thread's stack.
    final class Watchdog: @unchecked Sendable {
        private let recorder: Recorder
        private let limit: Double
        private let mainThread: thread_act_t
        private let answered = Mutex(Date())
        private let running = Mutex(true)
        private let stalls = Mutex<[(seconds: Double, stack: [String])]>([])

        /// Call on the main thread.
        init(recorder: Recorder, limit: Double = 2) {
            self.recorder = recorder
            self.limit = limit
            mainThread = mach_thread_self()
        }

        func start() {
            let thread = Thread { [self] in
                var reported = false
                while running.withLock({ $0 }) {
                    let sent = Date()
                    MainThread.post { [self] in answered.withLock { $0 = Date() } }
                    Thread.sleep(forTimeInterval: 0.1)
                    let last = answered.withLock { $0 }
                    let waited = Date().timeIntervalSince(last)
                    if waited > limit, !reported, last < sent {
                        reported = true
                        let stack = sampleMainThread()
                        stalls.withLock { $0.append((waited, stack)) }
                        recorder.write("hang", ["seconds": waited, "stack": stack])
                    } else if last >= sent {
                        if reported {
                            recorder.write("hang-ended", ["seconds": waited])
                        }
                        reported = false
                    }
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() {
            running.withLock { $0 = false }
        }

        /// Stalls since the last call: their lengths in seconds and where the main thread was.
        func takeStalls() -> [(seconds: Double, stack: [String])] {
            stalls.withLock { stalls in
                defer { stalls = [] }
                return stalls
            }
        }

        /// Whether the main thread is in one of `frames` now.
        func isMainThread(inAnyOf frames: [String]) -> Bool {
            sampleMainThread().contains { entry in frames.contains { entry.contains($0) } }
        }

        /// The main thread's call stack, by symbol: suspended, its frame pointers walked, resumed.
        private func sampleMainThread() -> [String] {
            var state = arm_thread_state64_t()
            var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
            var addresses: [UInt] = []
            addresses.reserveCapacity(64)
            guard thread_suspend(mainThread) == KERN_SUCCESS else { return [] }
            let result = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                    thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
                }
            }
            if result == KERN_SUCCESS {
                let mask: UInt = 0x0000_000F_FFFF_FFFF
                addresses.append(UInt(state.__pc) & mask)
                addresses.append(UInt(state.__lr) & mask)
                var fp = UInt(state.__fp)
                while fp != 0, fp & 7 == 0, addresses.count < 64,
                      let frame = UnsafePointer<UInt>(bitPattern: fp) {
                    addresses.append(frame[1] & mask)
                    let next = frame[0]
                    guard next > fp else { break }
                    fp = next
                }
            }
            thread_resume(mainThread)
            return addresses.map { address in
                var info = Dl_info()
                guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let name = info.dli_sname else {
                    return String(format: "0x%lx", address)
                }
                return String(cString: name)
            }
        }
    }

    enum Memory {
        /// What macOS charges the app for (Activity Monitor's Memory), in megabytes.
        static func footprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        }
    }

    extension NSView {
        /// Whether the view is drawn: neither it nor a view it's in is hidden or transparent.
        var isDrawn: Bool {
            !isHiddenOrHasHiddenAncestor && sequence(first: self, next: \.superview).allSatisfy { $0.alphaValue > 0 }
        }
    }

    @MainActor
    enum Snapshot {
        /// An image of the window in front (its sheet if one is up), canvas included, written
        /// without Screen Recording permission.
        static func capture(to url: URL) {
            guard let main = EditorWindowController.frontWindow ?? NSApp.windows.first(where: \.isVisible)
            else { return }
            capture(main.attachedSheet ?? main, to: url)
        }

        /// An image of `window` as it draws itself, each canvas's last frame in its place beneath the
        /// views over it (its Metal layer isn't in a view's drawing). A view outside the window's bounds
        /// isn't in it. Returns whether it was written.
        @discardableResult
        static func capture(_ window: NSWindow, to url: URL) -> Bool {
            guard let root = window.contentView?.superview ?? window.contentView,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)
            else { return false }
            // The module not shown keeps its canvas, transparent.
            let stands = Views.all(CanvasMetalView.self, in: root).filter(\.isDrawn).compactMap { canvas -> NSView? in
                guard let image = canvas.snapshotImage() else { return nil }
                let stand = NSImageView(frame: canvas.bounds)
                stand.image = NSImage(cgImage: image, size: canvas.bounds.size)
                stand.imageScaling = .scaleAxesIndependently
                canvas.addSubview(stand)
                return stand
            }
            root.cacheDisplay(in: root.bounds, to: rep)
            stands.forEach { $0.removeFromSuperview() }
            // A view's drawing fills the panels' glass in solid, over them: each panel is drawn again on it.
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                for item in Views.splitItems(in: window) where item.behavior != .default {
                    let panel = item.viewController.view
                    guard panel.isDrawn, let image = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else {
                        continue
                    }
                    panel.cacheDisplay(in: panel.bounds, to: image)
                    let frame = panel.convert(panel.bounds, to: root)
                    image.draw(in: root.isFlipped
                        ? NSRect(
                            x: frame.minX,
                            y: root.bounds.height - frame.maxY,
                            width: frame.width,
                            height: frame.height,
                        )
                        : frame)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
        }
    }
#endif
