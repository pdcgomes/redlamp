#if DEBUG || REDLAMP_PROFILING
    import AppKit
    @_spi(Harness) import RedlampUI

    /// The snapshot script's sheets: the Export dialog, and a sheet captured over its window.
    extension DebugSnapshot {
        /// Chooses Export… in the File menu, and with `scrolledToEnd` scrolls the dialog's
        /// settings to the last one once it's up. SwiftUI enables a menu's items as the menu
        /// opens, so it is brought up to date first. The dialog's modal loop holds main-actor tasks until it
        /// closes but runs the main run loop's common modes, so the work is scheduled there, and
        /// this comes last in a script.
        static func openExport(scrolledToEnd: Bool) {
            let title = ShortcutAction.export.title
            if scrolledToEnd {
                let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
                    MainActor.assumeIsolated { scrollSheetToEnd() }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    guard let menu = NSApp.mainMenu?.items.lazy.compactMap(\.submenu)
                        .first(where: { $0.indexOfItem(withTitle: title) >= 0 }) else { return }
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.delegate?.menuWillOpen?(menu)
                    menu.update()
                    AppDelegate.performMenuItem(titled: title)
                    menu.delegate?.menuDidClose?(menu)
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }

        /// Scrolls the open sheet's scroll view under its middle to the end. A scroll wheel made
        /// in the app reaches no scroll view, so the snapshot moves it as the scroller would.
        private static func scrollSheetToEnd() {
            guard let sheet = NSApp.windows.lazy.compactMap(\.attachedSheet).first,
                  let root = sheet.contentView,
                  let view = root.hitTest(NSPoint(x: root.bounds.midX, y: root.bounds.midY)),
                  let scroll = view.enclosingScrollView, let document = scroll.documentView
            else { return }
            document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
        }

        /// The window, then the sheet at its place on it, on a canvas holding both.
        static func composite(_ sheet: NSWindow, over window: NSWindow) -> NSBitmapImageRep? {
            guard let back = image(of: window), let front = image(of: sheet) else { return nil }
            let union = window.frame.union(sheet.frame)
            let scale = window.backingScaleFactor
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(union.width * scale), pixelsHigh: Int(union.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0,
            ) else { return nil }
            rep.size = union.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            back.draw(in: window.frame.offsetBy(dx: -union.minX, dy: -union.minY))
            front.draw(in: sheet.frame.offsetBy(dx: -union.minX, dy: -union.minY))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
    }
#endif
