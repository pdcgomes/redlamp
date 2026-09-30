import AppKit
import Observation
import RedlampDesign
import RedlampEngineAPI
@_spi(Harness) import RedlampUI
import SwiftUI

extension HarnessScene {
    static var panelPerformance: HarnessScene {
        HarnessScene(
            id: "performance-basic",
            title: "Basic panel drag",
            symbol: "gauge.with.dots.needle.67percent",
            synopsis: "Drags Exposure at 120 events a second through each implementation and measures how busy the main thread gets",
            section: .performance,
        ) {
            PerformanceScene()
        }
    }
}

private enum Implementation: String, CaseIterable, Identifiable {
    case appKit = "AppKit"
    case swiftUI = "SwiftUI"

    var id: String {
        rawValue
    }
}

@MainActor @Observable
private final class PerformanceRun {
    var implementation = Implementation.appKit
    var running = false
    var results: [(Implementation, MainThreadMonitor.Summary)] = []

    func sweep(seconds: Double = 3) async {
        let model = HarnessEditor.model
        let parameter = ParameterID.exposure
        let spec = parameter.spec
        running = true
        defer { running = false }
        try? await Task.sleep(for: .milliseconds(500))
        let monitor = MainThreadMonitor()
        monitor.start()
        model.beginEdit(parameter)
        let started = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - started < seconds {
            let t = (CFAbsoluteTimeGetCurrent() - started) / seconds
            model.setSliderValue(parameter, spec.value(atPosition: 0.5 + 0.35 * sin(t * .pi * 4)))
            try? await Task.sleep(for: .microseconds(8333))
        }
        model.endEdit(name: nil)
        monitor.stop()
        if let summary = monitor.summary(seconds: seconds) {
            results.append((implementation, summary))
        }
    }
}

private struct PerformanceScene: View {
    @State private var run = PerformanceRun()

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Implementation", selection: $run.implementation) {
                    ForEach(Implementation.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(run.running)
                Group {
                    switch run.implementation {
                    case .appKit:
                        AppKitSpecimen(width: 316) { BasicPanelView.make(model: HarnessEditor.model) }
                    case .swiftUI:
                        BasicPanel().environment(HarnessEditor.model).frame(width: 316)
                    }
                }
                .background(Palette.panelBackground.color)
            }

            VStack(alignment: .leading, spacing: 12) {
                Button(run.running ? "Dragging…" : "Run 3 s drag") {
                    Task { await run.sweep() }
                }
                .disabled(run.running)
                SpecimenGroup(
                    title: "Results",
                    note: "Busy is the share of the drag the main thread spent working. Smooth means iterations stay under a frame: 8.3 ms at 120 Hz.",
                ) {
                    Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            ForEach(["", "busy", "p50", "p95", "p99", "max", ">8.3 ms"], id: \.self) {
                                Text($0).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array(run.results.enumerated()), id: \.offset) { _, result in
                            let (implementation, summary) = result
                            GridRow {
                                Text(implementation.rawValue).gridColumnAlignment(.leading)
                                Text(String(format: "%.0f%%", summary.busy * 100))
                                Text(String(format: "%.2f", summary.p50))
                                Text(String(format: "%.2f", summary.p95))
                                Text(String(format: "%.2f", summary.p99))
                                Text(String(format: "%.1f", summary.max))
                                Text("\(summary.overFrame)")
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
        }
    }
}
