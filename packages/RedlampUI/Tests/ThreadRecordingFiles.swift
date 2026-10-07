import Foundation
import RedlampEngineAPI

/// A reader that finds no file to be an export, answers after `delay` as a decode service that
/// is starting or busy would, and records whether each call came on the main thread.
final class ThreadRecordingFiles: FileInspecting, @unchecked Sendable {
    private let delay: Duration
    private let lock = NSLock()
    private var calls: [(url: URL, onMain: Bool)] = []

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    var asked: [URL] {
        lock.withLock { calls.map(\.url) }
    }

    var mainThreadCalls: [URL] {
        lock.withLock { calls.filter(\.onMain).map(\.url) }
    }

    func captures(of urls: [URL], concurrently _: Bool) -> [CaptureSettings?] {
        record(urls)
        return urls.map { _ in nil }
    }

    func focusThumbnails(of urls: [URL], concurrently _: Bool) -> [GreyThumbnail?] {
        record(urls)
        return urls.map { _ in nil }
    }

    func imageProperties(of urls: [URL]) -> [ImageProperties?] {
        record(urls)
        return urls.map { _ in nil }
    }

    private func record(_ urls: [URL]) {
        let onMain = Thread.isMainThread
        lock.withLock { calls += urls.map { ($0, onMain) } }
        if delay > .zero {
            Thread
                .sleep(forTimeInterval: Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
        }
    }
}
