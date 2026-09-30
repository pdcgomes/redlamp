import AppKit
import RedlampDesign
import RedlampEngineAPI
@_spi(Harness) import RedlampUI
import SwiftUI

/// `--probe`: measures SwiftUI originals and their AppKit counterparts element by element,
/// writes the sizes to `/tmp/redlamp-probe.txt` and quits. Parity work starts here: a
/// panel that drifts by a few points usually has one element of the wrong height.
@MainActor
enum MetricsProbe {
    static func runIfRequested() {
        guard HarnessLaunch.arguments.contains("--probe") else { return }
        let model = HarnessEditor.model
        func swiftUI(_ view: some View) -> CGSize {
            NSHostingView(rootView: AnyView(view.environment(model))).fittingSize
        }
        func appKit(_ view: NSView) -> CGSize {
            view.layoutSubtreeIfNeeded()
            let size = view.intrinsicContentSize
            return CGSize(
                width: size.width == NSView.noIntrinsicMetric ? view.fittingSize.width : size.width,
                height: size.height == NSView.noIntrinsicMetric ? view.fittingSize.height : size.height,
            )
        }

        let segmented = NSSegmentedControl(
            labels: Treatment.allCases.map(\.name),
            trackingMode: .selectOne,
            target: nil,
            action: nil,
        )
        segmented.controlSize = .small
        let pullDown = NSPopUpButton(frame: .zero, pullsDown: true)
        pullDown.controlSize = .small
        pullDown.font = Typography.label.nsFont
        pullDown.addItems(withTitles: ["Redlamp Color", "Redlamp Color"])
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .small
        popUp.addItems(withTitles: WhiteBalanceMode.allCases.map(\.name))
        let auto = NSButton(title: "Auto", target: nil, action: nil)
        auto.bezelStyle = .push
        auto.controlSize = .mini

        var lines: [String] = []
        func row(_ name: String, _ reference: CGSize, _ candidate: CGSize) {
            let mark = reference == candidate ? "  ✓" : ""
            lines.append(String(
                format: "%-28@ SwiftUI %6.1f × %-5.1f  AppKit %6.1f × %-5.1f%@",
                name as NSString, reference.width, reference.height, candidate.width, candidate.height,
                mark as NSString,
            ))
        }
        for (name, font) in [
            ("text label 11", Typography.label), ("text value 11", Typography.value),
            ("text panelTitle 11.5", Typography.panelTitle), ("text section 10", Typography.section),
            ("text badge 9", Typography.badge),
        ] {
            let sample = name.contains("section") ? "PRESENCE" : "Exposure"
            row(
                name,
                swiftUI(Text(sample).font(font.font).tracking(font.tracking)),
                CGSize(width: TextLine.width(sample, font: font), height: TextLine.lineHeight(font)),
            )
        }
        let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        row(
            "chevron 9 bold",
            swiftUI(Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))),
            chevron?.size ?? .zero,
        )
        if let chevron {
            lines.append("chevron alignmentRect \(chevron.alignmentRect)")
        }
        row("button Auto mini", swiftUI(Button("Auto") {}.controlSize(.mini)), appKit(auto))
        row(
            "picker segmented small",
            swiftUI(Picker("T", selection: .constant(Treatment.color)) {
                ForEach(Treatment.allCases, id: \.self) { Text($0.name).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small)),
            appKit(segmented),
        )
        row(
            "menu button small",
            swiftUI(Menu { Button("A") {} } label: { Text("Redlamp Color").font(Theme.labelFont) }.menuStyle(.button)
                .controlSize(.small)),
            appKit(pullDown),
        )
        row(
            "picker popup small",
            swiftUI(Picker("W", selection: .constant(WhiteBalanceMode.asShot)) {
                ForEach(WhiteBalanceMode.allCases, id: \.self) { Text($0.name).tag($0) }
            }.labelsHidden().controlSize(.small)),
            appKit(popUp),
        )
        row(
            "subsection header",
            swiftUI(SubsectionHeader(title: "Presence", parameters: []).frame(width: 288)),
            appKit(SubsectionHeaderView(title: "Presence", parameters: [], editor: model)),
        )
        row(
            "subsection header + Auto",
            swiftUI(SubsectionHeader(title: "Tone", parameters: [.exposure]) {
                Button("Auto") {}.controlSize(.mini)
            }.frame(width: 288)),
            appKit(SubsectionHeaderView(title: "Tone", parameters: [.exposure], editor: model, accessory: auto)),
        )
        row(
            "slider row",
            swiftUI(ParameterSlider(parameter: .exposure).frame(width: 288)),
            appKit(SliderRowView(parameter: .exposure, editor: model)),
        )

        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(toFile: "/tmp/redlamp-probe.txt", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

private enum Theme {
    static let labelFont = Typography.label.font
}
