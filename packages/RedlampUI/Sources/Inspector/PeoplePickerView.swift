import RedlampEngineAPI
import SwiftUI

/// The People picker (UX-21), in the panel where the list was: who is in the photo, as crops to
/// tick, the parts to mask, and whether each person gets a mask of their own. The pointer over a
/// crop outlines that person on the photo.
struct PeoplePickerView: View {
    let picker: PeoplePicker
    @Environment(EditorModel.self) private var model

    private let crops = [GridItem(.adaptive(minimum: 64, maximum: 84), spacing: 8)]
    private let parts = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(picker.mode
                .target == nil ? "New People Mask" : "People · \(picker.mode.title(targetName: targetName))")
                .font(Theme.sectionFont)
                .foregroundStyle(Theme.secondaryLabel)
            people
            if picker.people?.isEmpty == false {
                partsList
                if picker.mode.target == nil, picker.chosen.count > 1 {
                    Toggle("Separate masks, one for each person", isOn: Binding(
                        get: { picker.separate },
                        set: { model.setPeopleSeparate($0) },
                    ))
                    .toggleStyle(.checkbox)
                    .font(Theme.labelFont)
                    .automationIdentifier("masks.people.separate")
                }
                if picker.mode.operation == .intersect, picker.parts.count > 1 {
                    Text("Intersect takes one part at a time.")
                        .font(Theme.labelFont)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
            HStack {
                Button("Cancel") { model.closePeoplePicker() }
                    .keyboardShortcut(.cancelAction)
                    .automationIdentifier("masks.people.cancel")
                Spacer()
                Button(createTitle) {
                    Task { await model.createPeopleMasks() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!picker.canCreate || model.aiMaskProgress != nil)
                .automationIdentifier("masks.people.create")
            }
            .controlSize(.small)
        }
        .onDisappear { model.hoveredPersonBox = nil }
    }

    @ViewBuilder private var people: some View {
        if let people = picker.people {
            if people.isEmpty {
                Text("No people were found in this photo.")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.secondaryLabel)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if people.count > 1 {
                        Toggle("All", isOn: Binding(
                            get: { picker.chosen.count == people.count },
                            set: { all in
                                for person in people where picker.chosen.contains(person.id) != all {
                                    model.togglePerson(person)
                                }
                            },
                        ))
                        .toggleStyle(.checkbox)
                        .font(Theme.labelFont)
                        .automationIdentifier("masks.people.all")
                    }
                    LazyVGrid(columns: crops, alignment: .leading, spacing: 8) {
                        ForEach(people) { person in
                            crop(person)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finding people…")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }

    private func crop(_ person: PersonFound) -> some View {
        let chosen = picker.chosen.contains(person.id)
        return Button {
            model.togglePerson(person)
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let image = model.peopleCrops[person.id] {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.square").font(.system(size: 22))
                                .foregroundStyle(Theme.tertiaryLabel)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .background(Theme.well)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(chosen ? Color.accentColor : Theme.divider, lineWidth: chosen ? 2 : 1))
                    Image(systemName: chosen ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(chosen ? Color.accentColor : Color.white)
                        .shadow(radius: 1)
                        .padding(4)
                }
                Text(picker.name(of: person))
                    .font(.system(size: 9.5))
                    .foregroundStyle(chosen ? Theme.value : Theme.secondaryLabel)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            model.hoveredPersonBox = inside ? person.box : nil
        }
        .help("\(chosen ? "Leave out" : "Include") \(picker.name(of: person))")
        .accessibilityLabel(picker.name(of: person))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .automationIdentifier("masks.people.person.\(person.id)")
    }

    private var partsList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PARTS")
                .font(Theme.sectionFont)
                .tracking(0.6)
                .foregroundStyle(Theme.tertiaryLabel)
            LazyVGrid(columns: parts, alignment: .leading, spacing: 4) {
                ForEach(model.availablePersonParts, id: \.self) { part in
                    Toggle(isOn: Binding(
                        get: { picker.parts.contains(part) },
                        set: { _ in model.togglePersonPart(part) },
                    )) {
                        HStack(spacing: 4) {
                            Text(part.name)
                            if let needed = picker.needsModel[part] {
                                Text(needed.name)
                                    .font(.system(size: 8.5, weight: .medium))
                                    .padding(.horizontal, 3)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.well))
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .help("Needs \(needed.name), a \(needed.formattedSize) download")
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(Theme.labelFont)
                    .lineLimit(1)
                    .automationIdentifier("masks.people.part.\(part.rawValue)")
                }
            }
        }
    }

    private var createTitle: String {
        if let operation = picker.mode.target.map({ _ in picker.mode.operation }) {
            return operation.name
        }
        return picker.separate && picker.chosen.count > 1 ? "Create \(picker.chosen.count) Masks" : "Create Mask"
    }

    private var targetName: String? {
        picker.mode.target.flatMap { target in model.maskOutlines.first { $0.id == target }?.name }
    }
}

/// The People picker while it's open, in the list's place, with the panel's margins.
struct OpenPeoplePicker: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        if let picker = model.peoplePicker {
            PeoplePickerView(picker: picker)
                .padding(.horizontal, Theme.panelPadding)
                .padding(.bottom, 12)
        }
    }
}

/// The picker with `count` people found, one ticked, for the harness's States.
@_spi(Harness) public struct PeoplePickerSpecimen: View {
    let count: Int

    public init(people count: Int) {
        self.count = count
    }

    public var body: some View {
        var picker = PeoplePicker(mode: .new)
        picker.people = (0 ..< count).map { index in
            PersonFound(instance: index, box: ImageRect(x: 0.1 + 0.3 * Double(index), y: 0.2, width: 0.2, height: 0.6))
        }
        picker.chosen = count > 1 ? [1] : []
        picker.parts = [.faceSkin]
        return PeoplePickerView(picker: picker)
            .padding(12)
            .frame(width: 300)
    }
}
