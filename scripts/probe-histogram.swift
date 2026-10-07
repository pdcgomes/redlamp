import AppKit
import SwiftUI

// What the histogram graph's references depend on, as this Mac sees it.

final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat {
        1
    }
}

@MainActor func probe() {
    _ = NSApplication.shared
    for screen in NSScreen.screens {
        print("screen \(screen.frame) visible \(screen.visibleFrame) scale \(screen.backingScaleFactor) "
            + "colour space \(screen.colorSpace?.localizedName ?? "none")")
    }
    print("appearance \(NSApp.effectiveAppearance.name.rawValue)")
    for size in [8.0, 9.0, 11.0] {
        let image = Image(systemName: "arrowtriangle.up.fill").font(.system(size: size))
        let alone = NSHostingView(rootView: image).fittingSize
        let hosted = NSHostingView(rootView: image)
        let window = OneXWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        let symbol = NSImage(systemSymbolName: "arrowtriangle.up.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        print(
            "triangle \(size) pt: SwiftUI \(alone), in a 1x window \(hosted.fittingSize), image \(symbol?.size ?? .zero), "
                + "alignment rect \(symbol?.alignmentRect ?? .zero)",
        )
    }
    let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    print("caption font \(font.fontName) ascender \(font.ascender) descender \(font.descender) leading \(font.leading)")
    for (name, color) in [("systemBlue", NSColor.systemBlue), ("systemRed", NSColor.systemRed)] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                if let c = color.usingColorSpace(.sRGB) {
                    print(
                        "\(name) \(appearance.rawValue): \(c.redComponent * 255) \(c.greenComponent * 255) \(c.blueComponent * 255)",
                    )
                }
            }
        }
    }
}

MainActor.assumeIsolated { probe() }
