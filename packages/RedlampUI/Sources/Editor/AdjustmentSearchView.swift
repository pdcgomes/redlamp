import RedlampEngineAPI
import SwiftUI

/// ⌘F: type a slider's name, or a word for it, then Return to open its panel and focus it.
struct AdjustmentSearchView: View {
    @Environment(EditorModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [AdjustmentSearch.Result] {
        AdjustmentSearch.results(for: query)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { model.showAdjustmentSearch = false }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryLabel)
                    TextField("Find an adjustment (for example “haze” or “white balance”)", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit(revealSelection)
                        .onChange(of: query) { _, _ in selection = 0 }
                }
                .padding(12)

                if !results.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    VStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            row(result, selected: index == selection)
                                .contentShape(Rectangle())
                                .onTapGesture { model.reveal(result.parameter) }
                        }
                    }
                    .padding(6)
                } else if !query.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    Text("No adjustment matches “\(query)”.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.secondaryLabel)
                        .padding(12)
                }
            }
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.45), radius: 24)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onExitCommand { model.showAdjustmentSearch = false }
        .transition(.opacity)
    }

    private func row(_ result: AdjustmentSearch.Result, selected: Bool) -> some View {
        HStack {
            Text(result.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
            Spacer()
            Text(result.context).font(Theme.captionFont).foregroundStyle(Theme.secondaryLabel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.white.opacity(0.1) : .clear))
    }

    private func revealSelection() {
        guard results.indices.contains(selection) else { return }
        model.reveal(results[selection].parameter)
    }
}
