import AppKit
import CoreImage
import RedlampDesign
import SwiftUI

/// How a parity scene compares the SwiftUI original with the AppKit port.
enum ParityMode: String, CaseIterable, Identifiable {
    /// Next to each other.
    case side
    /// Stacked, the port blended with `difference`: identical pixels are black.
    case difference
    /// Stacked, the port at half opacity.
    case onion
    /// Stacked, alternating twice a second: small shifts jump out.
    case flicker

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .side: "Side by side"
        case .difference: "Difference"
        case .onion: "Onion skin"
        case .flicker: "Flicker"
        }
    }

    static var launchDefault: ParityMode {
        HarnessLaunch.value(after: "--parity-mode").flatMap(ParityMode.init(rawValue:)) ?? .side
    }
}

/// Shows a SwiftUI original and its AppKit port at the same width, on the same surface.
///
/// `revision` rebuilds the port (after a knob changes a drawing constant).
struct ParityStage: NSViewRepresentable {
    let width: CGFloat
    let mode: ParityMode
    var revision = 0
    let reference: @MainActor () -> NSView
    let candidate: @MainActor () -> NSView

    func makeNSView(context _: Context) -> ParityContainerView {
        ParityContainerView(width: width, reference: reference(), candidate: candidate(), mode: mode)
    }

    func updateNSView(_ view: ParityContainerView, context: Context) {
        view.mode = mode
        if view.width != width {
            view.width = width
        }
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            view.replaceCandidate(candidate())
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(revision: revision)
    }

    final class Coordinator {
        var revision: Int

        init(revision: Int) {
            self.revision = revision
        }
    }

    func sizeThatFits(_: ProposedViewSize, nsView view: ParityContainerView, context _: Context) -> CGSize? {
        view.contentSize
    }
}

final class ParityContainerView: NSView, ColumnHost {
    var width: CGFloat {
        didSet { relayout() }
    }

    var mode: ParityMode {
        didSet {
            if mode != oldValue {
                applyMode()
            }
        }
    }

    private let referenceBox: SurfaceView
    private var candidateBox: SurfaceView
    private var flickerTimer: Timer?
    private static let gap: CGFloat = 24
    private static let captionHeight: CGFloat = 18

    init(width: CGFloat, reference: NSView, candidate: NSView, mode: ParityMode) {
        self.width = width
        self.mode = mode
        referenceBox = SurfaceView(content: reference)
        candidateBox = SurfaceView(content: candidate)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(referenceBox)
        addSubview(candidateBox)
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        MainActor.assumeIsolated { flickerTimer?.invalidate() }
    }

    override var isFlipped: Bool {
        true
    }

    func replaceCandidate(_ candidate: NSView) {
        candidateBox.removeFromSuperview()
        candidateBox = SurfaceView(content: candidate)
        addSubview(candidateBox)
        applyMode()
    }

    var contentSize: CGSize {
        let height = max(referenceBox.contentHeight(forWidth: width), candidateBox.contentHeight(forWidth: width))
        let columns: CGFloat = mode == .side ? 2 : 1
        return CGSize(
            width: width * columns + (mode == .side ? Self.gap : 0),
            height: height + Self.captionHeight,
        )
    }

    func columnContentDidChange() {
        relayout()
    }

    private func relayout() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private func applyMode() {
        flickerTimer?.invalidate()
        flickerTimer = nil
        candidateBox.compositingFilter = mode == .difference ? CIFilter(name: "CIDifferenceBlendMode") : nil
        candidateBox.alphaValue = mode == .onion ? 0.5 : 1
        candidateBox.isHidden = false
        if mode == .flicker {
            flickerTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.candidateBox.isHidden.toggle()
                    self.needsDisplay = true
                }
            }
        }
        relayout()
    }

    override func layout() {
        super.layout()
        let y = Self.captionHeight
        referenceBox.frame = CGRect(x: 0, y: y, width: width, height: referenceBox.contentHeight(forWidth: width))
        let candidateX = mode == .side ? width + Self.gap : 0
        candidateBox.frame = CGRect(
            x: candidateX,
            y: y,
            width: width,
            height: candidateBox.contentHeight(forWidth: width),
        )
    }

    override func draw(_: NSRect) {
        let font = FontSpec(size: 10, weight: .medium)
        let color = Palette.secondaryLabel.nsColor
        let referenceHeight = Int(referenceBox.contentHeight(forWidth: width).rounded())
        let candidateHeight = Int(candidateBox.contentHeight(forWidth: width).rounded())
        let heights = "SwiftUI \(referenceHeight) pt  ·  AppKit \(candidateHeight) pt"
        switch mode {
        case .side:
            TextLine.draw(
                "SwiftUI · \(referenceHeight) pt",
                font: font,
                color: color,
                in: CGRect(x: 0, y: 0, width: width, height: 14),
            )
            TextLine.draw(
                "AppKit · \(candidateHeight) pt", font: font, color: color,
                in: CGRect(x: width + Self.gap, y: 0, width: width, height: 14),
            )
        case .flicker:
            let showing = candidateBox.isHidden ? "SwiftUI" : "AppKit"
            TextLine.draw(
                "\(showing)  ·  \(heights)",
                font: font,
                color: color,
                in: CGRect(x: 0, y: 0, width: width, height: 14),
            )
        case .difference, .onion:
            TextLine.draw(heights, font: font, color: color, in: CGRect(x: 0, y: 0, width: width, height: 14))
        }
    }
}

/// An opaque panel-colored surface under a component, so a difference blend compares
/// finished pixels (component over background), not bare components.
final class SurfaceView: NSView {
    let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.panelBackground.cgColor
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        if let provider = content as? HeightProviding {
            return provider.height(forWidth: width)
        }
        if let hosting = content as? NSHostingView<AnyView> {
            return hosting.fittingSize.height
        }
        let intrinsic = content.intrinsicContentSize.height
        return intrinsic == NSView.noIntrinsicMetric ? content.fittingSize.height : intrinsic
    }

    override func layout() {
        super.layout()
        content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight(forWidth: bounds.width))
    }
}

/// A SwiftUI view hosted for comparison, at the stage's width.
@MainActor
func hostedReference(width: CGFloat, @ViewBuilder _ view: () -> some View) -> NSView {
    let hosting = NSHostingView(rootView: AnyView(view().frame(width: width, alignment: .topLeading)))
    hosting.sizingOptions = [.intrinsicContentSize]
    return hosting
}
