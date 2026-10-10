import RedlampEngineAPI
import SwiftUI

/// The Landscape picker (UX-26), in the panel where the list was: the regions SAM 3 finds in the
/// photo, each with its share of it, to tick, and whether each gets a mask of its own.
struct LandscapePickerView: View {
    let picker: LandscapePicker
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(picker.mode.target == nil
                ? "New Landscape Mask" : "Landscape · \(picker.mode.title(targetName: targetName))")
                .font(Theme.sectionFont)
                .foregroundStyle(Theme.secondaryLabel)
            regions
            if picker.mode.target == nil, picker.chosen.count > 1 {
                Toggle("Separate masks, one for each region", isOn: Binding(
                    get: { picker.separate },
                    set: { model.setLandscapeSeparate($0) },
                ))
                .toggleStyle(.checkbox)
                .font(Theme.labelFont)
                .automationIdentifier("masks.landscape.separate")
            }
            if picker.mode.operation == .intersect, picker.chosen.count > 1 {
                Text("Intersect takes one region at a time.")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            HStack {
                Button("Cancel") { model.closeLandscapePicker() }
                    .keyboardShortcut(.cancelAction)
                    .automationIdentifier("masks.landscape.cancel")
                Spacer()
                Button(createTitle) {
                    Task { await model.createLandscapeMasks() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!picker.canCreate || model.aiMaskProgress != nil)
                .automationIdentifier("masks.landscape.create")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var regions: some View {
        if let regions = picker.regions {
            if regions.isEmpty {
                Text("No landscape regions were found in this photo.")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.secondaryLabel)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("REGIONS")
                        .font(Theme.sectionFont)
                        .tracking(0.6)
                        .foregroundStyle(Theme.tertiaryLabel)
                    ForEach(regions) { region in
                        row(region)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finding regions…")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }

    private func row(_ region: LandscapeFound) -> some View {
        Toggle(isOn: Binding(
            get: { picker.chosen.contains(region.landscape) },
            set: { _ in model.toggleLandscape(region.landscape) },
        )) {
            HStack {
                Text(region.landscape.name)
                Spacer()
                Text(Self.share(region.share))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .toggleStyle(.checkbox)
        .font(Theme.labelFont)
        .help("\(region.landscape.name) covers \(Self.share(region.share)) of the photo")
        .automationIdentifier("masks.landscape.region.\(region.landscape.rawValue)")
    }

    /// "34%"; "<1%" for a sliver.
    static func share(_ share: Double) -> String {
        share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }

    private var createTitle: String {
        if picker.mode.target != nil {
            return picker.mode.operation.name
        }
        return picker.separate && picker.chosen.count > 1 ? "Create \(picker.chosen.count) Masks" : "Create Mask"
    }

    private var targetName: String? {
        picker.mode.target.flatMap { target in model.maskOutlines.first { $0.id == target }?.name }
    }
}

/// The Landscape picker while it's open, in the list's place, with the panel's margins.
struct OpenLandscapePicker: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        if let picker = model.landscapePicker {
            LandscapePickerView(picker: picker)
                .padding(.horizontal, Theme.panelPadding)
                .padding(.bottom, 12)
        }
    }
}

/// The picker with four regions found and two ticked, or none found, for the harness's States.
@_spi(Harness) public struct LandscapePickerSpecimen: View {
    let found: Bool

    public init(found: Bool = true) {
        self.found = found
    }

    public var body: some View {
        var picker = LandscapePicker(mode: .new)
        picker.regions = found ? [
            LandscapeFound(landscape: .water, share: 0.21),
            LandscapeFound(landscape: .vegetation, share: 0.34),
            LandscapeFound(landscape: .mountains, share: 0.18),
            LandscapeFound(landscape: .naturalGround, share: 0.004),
        ] : []
        picker.chosen = found ? [.water, .vegetation] : []
        return LandscapePickerView(picker: picker)
            .padding(12)
            .frame(width: 300)
    }
}
