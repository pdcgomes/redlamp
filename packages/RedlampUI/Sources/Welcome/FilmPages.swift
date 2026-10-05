import AppKit
import AVFoundation
import RedlampDesign
import SwiftUI

/// The pages the welcome window and What's New set over the film: its wall and its one light, the
/// glow behind the logo, in the system font.
struct PageTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 26, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Brand.ring.opacity(0.85).color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.paper.opacity(0.62).color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The page's one way on, in the website's primary button. Return presses it.
struct PageButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).frame(minWidth: 112)
        }
        .buttonStyle(SafelightButtonStyle())
        .keyboardShortcut(.defaultAction)
    }
}

/// The website's primary button (`.button-primary` in web/app/globals.css): a pill of the
/// safelight, lit from above, its glow beneath breathing slowly. Only for the welcome and What's
/// New, once a page; the editor's buttons stay native and neutral.
struct SafelightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SafelightButton(configuration: configuration)
    }
}

private struct SafelightButton: View {
    static let top = Color(red: 232 / 255, green: 81 / 255, blue: 63 / 255)
    static let bottom = Color(red: 201 / 255, green: 48 / 255, blue: 31 / 255)
    static let text = Color(red: 1, green: 244 / 255, blue: 238 / 255)

    let configuration: ButtonStyleConfiguration
    @State private var breathing = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    /// The site's 0.35, breathing between 0.2 and 0.5; still with Reduce Motion.
    private var glow: Double {
        reduceMotion ? 0.35 : breathing ? 0.5 : 0.2
    }

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Self.text)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background {
                Capsule().fill(LinearGradient(
                    stops: [
                        .init(color: Self.top, location: 0),
                        .init(color: Brand.safelight.color, location: 0.55),
                        .init(color: Self.bottom, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom,
                ))
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.25),
                    ),
                    lineWidth: 1,
                )
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .shadow(color: Brand.safelight.opacity(glow).color, radius: 14, y: 8)
            .offset(y: hovering && !reduceMotion ? -1 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.2), value: hovering)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

/// The website's secondary button (`.button-secondary`): a pill of faint paper with a hairline,
/// for a page's other actions.
struct PaperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaperButton(configuration: configuration)
    }
}

private struct PaperButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Brand.paper.color)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule()
                .fill(Brand.paper.opacity(configuration.isPressed ? 0.14 : hovering ? 0.1 : 0.06).color))
            .overlay(Capsule().strokeBorder(Brand.paper.opacity(0.16).color, lineWidth: 1))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// Comes up the way the film's words do, as a print does in the developer: from faint and soft to
/// sharp, rising a little (`Develop` in video/src/introducing/components/Type.tsx, at half its
/// 1080p sizes).
struct Develop<Content: View>: View {
    var delay: Double = 0
    @ViewBuilder let content: Content
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .opacity(up ? 1 : 0)
            .blur(radius: up || reduceMotion ? 0 : 4.5)
            .offset(y: up || reduceMotion ? 0 : 6)
            .onAppear {
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.2).delay(delay)) {
                    up = true
                }
            }
    }
}

private struct DevelopOut: ViewModifier {
    let gone: Double

    func body(content: Content) -> some View {
        content
            .opacity(1 - gone)
            .blur(radius: gone * 3.5)
            .offset(y: -gone * 3)
    }
}

extension AnyTransition {
    /// How the film's words go: they soften and fade as they lift.
    static var developOut: AnyTransition {
        .modifier(active: DevelopOut(gone: 1), identity: DevelopOut(gone: 0))
    }
}

/// The film, filling the window, in a layer AVFoundation draws into.
struct FilmView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context _: Context) -> NSView {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        let view = NSView()
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

/// The window the film fills, titlebar included: dark, on the film's wall, with only a close button.
@MainActor
enum FilmWindow {
    static func make(title: String, size: CGSize, content: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false,
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Brand.wall.nsColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // The film fills the window, titlebar included; left to size it, SwiftUI adds the titlebar.
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        window.contentView = hosting
        return window
    }

    /// Centred on `editor`, kept on its screen.
    static func centre(_ window: NSWindow, over editor: NSWindow?) {
        guard let editor, let screen = editor.screen ?? NSScreen.main else {
            window.center()
            return
        }
        let frame = window.frame
        let visible = screen.visibleFrame
        window.setFrameOrigin(CGPoint(
            x: min(max(editor.frame.midX - frame.width / 2, visible.minX), visible.maxX - frame.width),
            y: min(max(editor.frame.midY - frame.height / 2, visible.minY), visible.maxY - frame.height),
        ))
    }
}
