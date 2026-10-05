import Foundation

/// One file fetched to disk, reporting the bytes as they arrive. When it fails or is cancelled
/// partway, what arrived is kept beside it as URLSession's resume data (`<file>.resume`), and the
/// next attempt carries on from there instead of starting again.
final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let received: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse?, any Error>?
    private var moveError: (any Error)?

    private init(destination: URL, received: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.received = received
    }

    static func resumeFile(for destination: URL) -> URL {
        destination.appendingPathExtension("resume")
    }

    /// Fetches `url` into `destination`; `received` hears the bytes so far. Returns the response.
    static func fetch(
        _ url: URL, to destination: URL, received: @escaping @Sendable (Int64) -> Void,
    ) async throws -> URLResponse? {
        let resumeFile = resumeFile(for: destination)
        let delegate = FileDownload(destination: destination, received: received)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = if let data = try? Data(contentsOf: resumeFile) {
            session.downloadTask(withResumeData: data)
        } else {
            session.downloadTask(with: url)
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.lock.withLock { delegate.continuation = continuation }
                    task.resume()
                }
            } onCancel: {
                task.cancel { data in
                    try? data?.write(to: resumeFile)
                }
            }
            try? FileManager.default.removeItem(at: resumeFile)
            return response
        } catch {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeFile)
            }
            throw error
        }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite _: Int64,
    ) {
        received(totalBytesWritten)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, moveError) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, self.moveError)
        }
        if let error = error ?? moveError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: task.response)
        }
    }
}

/// Passes on progress at most every thousandth, so a 2 GB file doesn't send the UI tens of
/// thousands of updates.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func callAsFunction(_ fraction: Double) {
        let due = lock.withLock {
            guard fraction >= 1 || fraction - last >= 0.001 else { return false }
            last = fraction
            return true
        }
        if due {
            report(fraction)
        }
    }
}
