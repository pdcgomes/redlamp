import AppKit
import RedlampEngineAPI
import SwiftUI

/// RGB histogram with Lightroom's clipping indicators and drag-to-adjust regions.
@_spi(Harness) public struct HistogramView: View {
    @Environment(EditorModel.self) private var model
    @State private var hoverRegion: Region?
    @State private var dragRegion: Region?
    @State private var dragStartValue = 0.0

    /// Horizontal regions of the histogram and the Basic slider each one drives.
    enum Region: CaseIterable {
        case blacks, shadows, exposure, highlights, whites

        var parameter: ParameterID {
            switch self {
            case .blacks: .blacks
            case .shadows: .shadows
            case .exposure: .exposure
            case .highlights: .highlights
            case .whites: .whites
            }
        }

        var span: ClosedRange<Double> {
            switch self {
            case .blacks: 0 ... 0.08
            case .shadows: 0.08 ... 0.32
            case .exposure: 0.32 ... 0.68
            case .highlights: 0.68 ... 0.92
            case .whites: 0.92 ... 1
            }
        }

        static func at(_ fraction: Double) -> Region {
            allCases.first { $0.span.contains(fraction) } ?? .exposure
        }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.well)

                    if let region = hoverRegion ?? dragRegion, model.info != nil {
                        let width = geometry.size.width
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .frame(width: (region.span.upperBound - region.span.lowerBound) * width)
                            .position(
                                x: (region.span.lowerBound + region.span.upperBound) / 2 * width,
                                y: geometry.size.height / 2,
                            )
                    }

                    Canvas { context, size in
                        draw(model.histogram, in: context, size: size)
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                    HStack {
                        clippingIndicator(clipped: model.histogram.shadowsClipped, color: .blue, flipped: false)
                        Spacer()
                        if let region = hoverRegion ?? dragRegion, model.info != nil {
                            Text(
                                "\(region.parameter.spec.label)  \(region.parameter.spec.formatted(model.value(region.parameter)))",
                            )
                            .font(Theme.captionFont.monospacedDigit())
                            .foregroundStyle(Theme.value)
                        }
                        Spacer()
                        clippingIndicator(clipped: model.histogram.highlightsClipped, color: .red, flipped: true)
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        hoverRegion = Region.at(location.x / max(geometry.size.width, 1))
                    case .ended:
                        hoverRegion = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { gesture in
                            guard model.info != nil else { return }
                            if dragRegion == nil {
                                let region = Region.at(gesture.startLocation.x / max(geometry.size.width, 1))
                                dragRegion = region
                                dragStartValue = model.value(region.parameter)
                                model.beginEdit(region.parameter)
                            }
                            guard let region = dragRegion else { return }
                            let spec = region.parameter.spec
                            let span = spec.range.upperBound - spec.range.lowerBound
                            let delta = gesture.translation.width / geometry.size.width * span * 0.6
                            model.setValue(region.parameter, dragStartValue + delta)
                        }
                        .onEnded { _ in
                            dragRegion = nil
                            model.endEdit()
                        },
                )
            }
            .frame(height: 104)

            HStack(spacing: 12) {
                if let info = model.info {
                    ForEach(info.exposureSummary, id: \.self) { part in
                        Text(part)
                    }
                } else {
                    Text(" ")
                }
            }
            .font(Theme.captionFont.monospacedDigit())
            .foregroundStyle(Theme.secondaryLabel)
            .frame(maxWidth: .infinity)
        }
    }

    private func clippingIndicator(clipped: Bool, color: Color, flipped: Bool) -> some View {
        Button {
            model.showClipping.toggle()
        } label: {
            Image(systemName: flipped ? "arrowtriangle.up.fill" : "arrowtriangle.up.fill")
                .font(.system(size: 8))
                .foregroundStyle(clipped || model.showClipping ? color : Theme.tertiaryLabel)
                .rotationEffect(.degrees(flipped ? 45 : -45))
                .frame(width: 14, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.showClipping ? "Hide clipping (J)" : "Show clipping (J)")
    }

    private func draw(_ histogram: Histogram, in context: GraphicsContext, size: CGSize) {
        let channels: [([UInt32], Color)] = [
            (histogram.red, Color(red: 0.95, green: 0.25, blue: 0.25)),
            (histogram.green, Color(red: 0.25, green: 0.9, blue: 0.35)),
            (histogram.blue, Color(red: 0.3, green: 0.45, blue: 1.0)),
        ]
        let peak = channels.flatMap { Array($0.0.dropFirst().dropLast()) }.max() ?? 0
        guard peak > 0 else { return }
        let scale = sqrt(Double(peak))

        var layer = context
        layer.blendMode = .plusLighter
        for (bins, color) in channels {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, count) in bins.enumerated() {
                let x = Double(index) / Double(bins.count - 1) * size.width
                let y = size.height - min(sqrt(Double(count)) / scale, 1) * size.height
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            layer.fill(path, with: .color(color.opacity(0.55)))
        }
    }
}

/// Crop, healing, red eye and masking tools, as in Lightroom's tool strip.
struct ToolStrip: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditTool.allCases) { tool in
                Button {
                    model.activeTool = model.activeTool == tool && tool != .edit ? .edit : tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(model.activeTool == tool ? Theme.value : Theme.secondaryLabel)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(model.activeTool == tool ? Theme.selection : .clear),
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.shortcut.isEmpty ? tool.title : "\(tool.title) (\(tool.shortcut))")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
    }
}

/// Shown in place of the panels for tools that are not built yet.
struct PlannedToolCard: View {
    let tool: EditTool
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tool.title, systemImage: tool.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.value)
            Text(tool.summary)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
            if let phase = tool.plannedPhase {
                Text("Arrives in \(phase).")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Button("Back to Edit") { model.activeTool = .edit }
                .controlSize(.small)
        }
        .padding(Theme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
