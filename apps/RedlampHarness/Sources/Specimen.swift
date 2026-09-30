import AppKit
import RedlampDesign
import SwiftUI

/// A titled band of specimens with a note on what would be wrong with them: a gallery
/// shows you a component, a note on what to look for turns looking into reviewing.
struct SpecimenGroup<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 640, alignment: .leading)
                }
            }
            content
        }
        .padding(.bottom, 28)
    }
}

/// One component with a monospaced caption.
struct Specimen<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            Text(caption)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }
}

/// Hosts an AppKit component at a fixed width and its own height, the way a panel hosts
/// it: `HeightProviding` views get the height they ask for at that width.
struct AppKitSpecimen: NSViewRepresentable {
    let width: CGFloat
    var revision = 0
    let make: @MainActor () -> NSView

    func makeNSView(context _: Context) -> SpecimenHostView {
        SpecimenHostView(content: make())
    }

    func updateNSView(_ view: SpecimenHostView, context: Context) {
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            view.content = make()
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

    func sizeThatFits(_: ProposedViewSize, nsView view: SpecimenHostView, context _: Context) -> CGSize? {
        CGSize(width: width, height: view.contentHeight(forWidth: width))
    }
}

final class SpecimenHostView: NSView, ColumnHost {
    var content: NSView {
        didSet {
            oldValue.removeFromSuperview()
            addSubview(content)
            needsLayout = true
        }
    }

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
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
        let intrinsic = content.intrinsicContentSize.height
        return intrinsic == NSView.noIntrinsicMetric ? content.fittingSize.height : intrinsic
    }

    override func layout() {
        super.layout()
        content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight(forWidth: bounds.width))
    }

    func columnContentDidChange() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        // SwiftUI re-asks `sizeThatFits` on the next update.
        superview?.needsLayout = true
    }
}
