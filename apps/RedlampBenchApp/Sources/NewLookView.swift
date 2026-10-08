import PhotosUI
import RedlampBench
import SwiftUI

/// A new look reference: exactly which look is being replicated, and which kit images to run
/// through it.
struct NewLookView: View {
    @Bindable var model: BenchModel
    let created: (BenchFolder) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var app = ""
    @State private var filter = ""
    @State private var variant = ""
    @State private var settings = ""
    @State private var kitSet = BenchManifest.LookReference.KitSet.standard
    @State private var screenshotItem: PhotosPickerItem?
    @State private var screenshot: PickedFile?

    var body: some View {
        let screenshotLabel = screenshot == nil ? "Add a Screenshot of the Settings" : "Screenshot Added"
        return NavigationStack {
            Form {
                Section {
                    TextField("App", text: $app)
                        .textInputAutocapitalization(.words)
                    if app.isEmpty, !model.knownApps.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(model.knownApps, id: \.self) { name in
                                    Button(name) { app = name }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                    TextField("Filter, as the app names it", text: $filter)
                    TextField("Variant, if it has several", text: $variant)
                } header: {
                    Text("The look")
                }
                Section {
                    TextField("Strength, sliders, anything away from the defaults", text: $settings, axis: .vertical)
                        .lineLimit(2 ... 6)
                    PhotosPicker(selection: $screenshotItem, matching: .screenshots) {
                        Label(screenshotLabel, systemImage: "camera.viewfinder")
                    }
                } header: {
                    Text("Settings")
                } footer: {
                    Text("Different settings make a different look, so they get a reference of their own.")
                }
                Section {
                    Picker("Kit", selection: $kitSet) {
                        Text("Quick: 1 image").tag(BenchManifest.LookReference.KitSet.quick)
                        Text("Standard: 3 charts, 2 photos").tag(BenchManifest.LookReference.KitSet.standard)
                        Text("Full: 3 charts, 8 photos").tag(BenchManifest.LookReference.KitSet.full)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Capture kit")
                } footer: {
                    Text(kitFooter)
                }
                if !model.kitAvailable {
                    Section {
                        Text(
                            "The capture kit comes from the Lab. Open the app while the Lab is reachable once, then try again.",
                        )
                        .foregroundStyle(.secondary)
                        Button("Check Now") { Task { await model.refresh() } }
                    }
                }
            }
            .navigationTitle("New Look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let look = BenchManifest.LookReference(
                            app: app.trimmingCharacters(in: .whitespaces),
                            filter: filter.trimmingCharacters(in: .whitespaces),
                            variant: variant.isEmpty ? nil : variant,
                            settings: settings.isEmpty ? nil : settings,
                            kitSet: kitSet,
                        )
                        if let folder = model.newLook(look, screenshot: screenshot?.url) {
                            created(folder)
                        }
                    }
                    .disabled(filter.trimmingCharacters(in: .whitespaces).isEmpty || !model.kitAvailable)
                }
            }
            .onAppear(perform: prefill)
            .onChange(of: screenshotItem) { _, item in
                Task { screenshot = try? await item?.loadTransferable(type: PickedFile.self) }
            }
        }
    }

    private var kitFooter: String {
        switch kitSet {
        case .quick: "One image holds the charts and small photos: about 30 seconds a filter."
        case .standard: "The three colour charts and two photos, for vignette, grain and skin: five exports."
        case .full: "Every kit image, for the closest match and a score on eight photos: eleven exports."
        }
    }

    private func prefill() {
        guard let last = model.nextLook else { return }
        app = last.app
        filter = last.filter
        variant = last.variant ?? ""
        settings = last.settings ?? ""
        kitSet = last.kitSet
    }
}
