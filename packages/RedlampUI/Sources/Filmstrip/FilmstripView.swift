import RedlampDocument
import SwiftUI

struct FilmstripView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let folder = model.folder {
                    Label(folder.lastPathComponent, systemImage: "folder")
                }
                Text("\(model.items.count) photos")
                    .foregroundStyle(Theme.tertiaryLabel)
                Spacer()
                if let info = model.info {
                    Text(info.fileName)
                    Text("\(info.pixelSize.width) × \(info.pixelSize.height)  ·  \(info.sensorDescription)")
                        .foregroundStyle(Theme.tertiaryLabel)
                }
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.secondaryLabel)
            .padding(.horizontal, 12)
            .frame(height: 22)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(model.items) { item in
                            FilmstripCell(item: item, isSelected: item.url == model.selection)
                                .id(item.url)
                                .onTapGesture { model.select(item.url) }
                                .task { await model.loadThumbnail(for: item.url) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, selection in
                    guard let selection else { return }
                    withAnimation(.snappy) { proxy.scrollTo(selection, anchor: .center) }
                }
            }
        }
        .frame(height: 104)
        .background(Color(white: 0.09))
    }
}

private struct FilmstripCell: View {
    let item: LibraryItem
    let isSelected: Bool
    @Environment(EditorModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: isSelected ? 0.22 : 0.14))
            if let thumbnail = model.thumbnails[item.url] {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                ProgressView().controlSize(.mini)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if item.hasEdits {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(3)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(6)
            }
        }
        .frame(width: 96, height: 70)
        .overlay(alignment: .topLeading) { flagBadge }
        .overlay(alignment: .bottomLeading) { stars }
        .overlay(alignment: .top) {
            if let label = item.metadata.label {
                Capsule().fill(label.color).frame(height: 3).padding(.horizontal, 6).padding(.top, 2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.white.opacity(0.85) : .clear, lineWidth: 1.5),
        )
        .opacity(item.metadata.flag == .reject ? 0.45 : 1)
        .help(item.name)
    }

    @ViewBuilder
    private var flagBadge: some View {
        switch item.metadata.flag {
        case .pick:
            Image(systemName: "flag.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.white)
                .padding(5)
        case .reject:
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(5)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stars: some View {
        if item.metadata.rating > 0 {
            HStack(spacing: 1) {
                ForEach(0 ..< item.metadata.rating, id: \.self) { _ in
                    Image(systemName: "star.fill").font(.system(size: 6))
                }
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(4)
        }
    }
}

extension ColorLabel {
    var color: Color {
        switch self {
        case .red: Color(red: 0.9, green: 0.25, blue: 0.25)
        case .yellow: Color(red: 0.95, green: 0.8, blue: 0.2)
        case .green: Color(red: 0.3, green: 0.8, blue: 0.35)
        case .blue: Color(red: 0.3, green: 0.5, blue: 0.95)
        case .purple: Color(red: 0.65, green: 0.4, blue: 0.9)
        }
    }
}
