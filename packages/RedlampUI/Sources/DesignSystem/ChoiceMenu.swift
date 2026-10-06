import SwiftUI

/// An option of a `ChoiceMenu`: its name, and the glyph shown beside it.
protocol MenuChoice: Hashable {
    var name: String { get }
    var symbol: String { get }
}

/// A choice among a few options, as a pop-up menu showing each option's glyph beside its name:
/// unlike a segmented control, it keeps its row's label column and never truncates a name.
struct ChoiceMenu<Choice: MenuChoice>: View {
    let title: String
    @Binding var selection: Choice
    let choices: [Choice]

    init(_ title: String, selection: Binding<Choice>, choices: [Choice]) {
        self.title = title
        _selection = selection
        self.choices = choices
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(choices, id: \.self) { choice in
                Label(choice.name, systemImage: choice.symbol).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

extension ChoiceMenu where Choice: CaseIterable {
    init(_ title: String, selection: Binding<Choice>) {
        self.init(title, selection: selection, choices: Array(Choice.allCases))
    }
}
