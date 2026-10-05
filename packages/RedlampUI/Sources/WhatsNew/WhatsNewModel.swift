import AppKit
import AVFoundation
import Observation

/// What's New's steps: the welcome film's last two seconds, silent, as the logo rises, then the
/// highlights beneath it, then a page for each.
@MainActor
@Observable
final class WhatsNewModel {
    enum Step: Equatable {
        case film, highlights
        case page(Int)
    }

    /// Where the film's logo sits centred, before it rises (frames 335 to 380 of the welcome film's
    /// 500, at 30 fps; video/src/introducing/Welcome.tsx).
    static let filmStart = CMTime(value: 305, timescale: 30)

    let items: [WhatsNewItem]
    let images: [String: NSImage]
    private(set) var step: Step
    /// Hidden until the film has moved to its start, so its dark opening never shows.
    private(set) var filmOpacity = 0.0
    @ObservationIgnored let player: AVPlayer?
    /// Done, on the last page.
    @ObservationIgnored var onFinish: () -> Void = {}
    /// A page's button.
    @ObservationIgnored var onAction: (WhatsNewItem.Action) -> Void = { _ in }
    @ObservationIgnored private var pagesObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    /// Without a film, or with Reduce Motion on, it opens on the highlights.
    init(pages: WhatsNewPages, film: URL?, reduceMotion: Bool) {
        items = pages.items
        images = pages.images
        player = film.map(AVPlayer.init(url:))
        player?.isMuted = true
        step = player == nil || reduceMotion ? .highlights : .film
    }

    /// "What's New in Redlamp 0.2.4" when every highlight is in that version.
    var title: String {
        let versions = Set(items.map(\.version))
        guard versions.count == 1, let version = versions.first else { return "What's New in Redlamp" }
        return "What's New in Redlamp \(version.short)"
    }

    func start() {
        guard let player else { return }
        guard step == .film else {
            player.seek(to: WelcomeModel.lastFrame, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.filmOpacity = 1 }
            }
            return
        }
        pagesObserver = player
            .addBoundaryTimeObserver(forTimes: [NSValue(time: WelcomeModel.pagesAt)], queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.showHighlights() }
            }
        statusObservation = player.currentItem?.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.showHighlights() }
        }
        player.seek(to: Self.filmStart, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.filmOpacity = 1
                self?.player?.play()
            }
        }
    }

    /// Continue and Next; Done on the last page. During the film, it skips to the highlights.
    func next() {
        switch step {
        case .film: skip()
        case .highlights: step = .page(0)
        case let .page(index) where index + 1 < items.count: step = .page(index + 1)
        case .page: onFinish()
        }
    }

    func back() {
        switch step {
        case .film, .highlights: break
        case .page(0): step = .highlights
        case let .page(index): step = .page(index - 1)
        }
    }

    /// A highlight's row, on the first page.
    func show(page index: Int) {
        guard items.indices.contains(index) else { return }
        step = .page(index)
    }

    func perform(_ action: WhatsNewItem.Action) {
        onAction(action)
    }

    func showHighlights() {
        if step == .film {
            step = .highlights
        }
    }

    private func skip() {
        showHighlights()
        player?.pause()
        player?.seek(to: WelcomeModel.lastFrame, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The window is closing.
    func stop() {
        player?.pause()
        if let pagesObserver {
            player?.removeTimeObserver(pagesObserver)
        }
        pagesObserver = nil
        statusObservation = nil
    }
}
