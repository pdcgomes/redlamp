import AVFoundation
import Observation

/// The welcome window's steps: the film's opening, then two pages over the film's last frame, where
/// the logo has risen to the top (video/src/introducing/Welcome.tsx).
@MainActor
@Observable
final class WelcomeModel {
    enum Step: Equatable {
        case film, about, help
    }

    /// Near the end of the logo's rise (frames 335 to 380 of the film's 500, at 30 fps), so the
    /// first page comes up as the logo settles above it.
    static let pagesAt = CMTime(value: 366, timescale: 30)
    /// A frame of the held last picture (from frame 380), where Skip and Reduce Motion go.
    static let lastFrame = CMTime(value: 420, timescale: 30)

    private(set) var step: Step
    /// Dims while Skip moves the film to its last frame.
    private(set) var filmOpacity = 1.0
    @ObservationIgnored let player: AVPlayer?
    /// Start Editing, on the last page.
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored private var pagesObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    /// Without a film, or with Reduce Motion on, it opens on the first page.
    init(film: URL?, reduceMotion: Bool) {
        player = film.map(AVPlayer.init(url:))
        step = player == nil || reduceMotion ? .about : .film
    }

    func start() {
        guard let player else { return }
        guard step == .film else {
            player.seek(to: Self.lastFrame, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        pagesObserver = player
            .addBoundaryTimeObserver(forTimes: [NSValue(time: Self.pagesAt)], queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.showPages() }
            }
        // A film that can't be played leaves the pages over the wall.
        statusObservation = player.currentItem?.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.showPages() }
        }
        player.play()
    }

    /// From the film to the first page: its sound fades, and the picture dims to the last frame
    /// and comes back up.
    func skip() {
        guard step == .film else { return }
        showPages()
        guard let player else { return }
        filmOpacity = 0
        Task {
            for volume in [0.75, 0.5, 0.25, 0] {
                player.volume = Float(volume)
                try? await Task.sleep(for: .milliseconds(60))
            }
            player.pause()
            player.seek(to: Self.lastFrame, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.filmOpacity = 1 }
            }
        }
    }

    /// Continue, then Start Editing. During the film, it skips.
    func next() {
        switch step {
        case .film: skip()
        case .about: step = .help
        case .help: onFinish()
        }
    }

    func showPages() {
        if step == .film {
            step = .about
        }
    }

    /// The window is closing: the sound stops with it.
    func stop() {
        player?.pause()
        if let pagesObserver {
            player?.removeTimeObserver(pagesObserver)
        }
        pagesObserver = nil
        statusObservation = nil
    }
}
