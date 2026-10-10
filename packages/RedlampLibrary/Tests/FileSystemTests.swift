import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

struct FileSystemTests {
    private let files = LocalFileSystem()

    @Test func `a listing carries each entry's size, date, kind and identifier, and leaves hidden files out`() throws {
        let folder = try TemporaryFolder()
        try folder.write("IMG_0001.JPG", bytes: 10)
        try folder.write("IMG_0002.ARW", bytes: 20)
        try folder.write("IMG_0001.JPG.redlamp/edit.json", bytes: 2)
        try folder.write(".DS_Store", bytes: 4)
        try folder.write("Selects/IMG_0003.JPG", bytes: 30)
        var hidden = folder.url.appending(path: "Hidden", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isHidden = true
        try hidden.setResourceValues(values)

        let entries = try files.contentsOfDirectory(at: folder.url).sorted { $0.name < $1.name }
        #expect(entries.map(\.name) == ["IMG_0001.JPG", "IMG_0001.JPG.redlamp", "IMG_0002.ARW", "Selects"])
        #expect(entries.map(\.isDirectory) == [false, true, false, true])
        #expect(entries[0].size == 10 && entries[2].size == 20)
        #expect(abs(entries[0].modified.timeIntervalSinceNow) < 60)
        let identifiers = entries.compactMap(\.fileIdentifier)
        #expect(identifiers.count == 4 && Set(identifiers).count == 4)
    }

    @Test func `a file keeps its identifier when it's renamed, and its attributes match its listing`() throws {
        let folder = try TemporaryFolder()
        try folder.write("IMG_0001.JPG", bytes: 10)
        let listed = try #require(try files.contentsOfDirectory(at: folder.url).first)
        let before = try files.attributes(of: folder.url.appending(path: "IMG_0001.JPG"))
        #expect(before == listed)

        try FileManager.default.moveItem(
            at: folder.url.appending(path: "IMG_0001.JPG"), to: folder.url.appending(path: "Renamed.JPG"),
        )
        let after = try files.attributes(of: folder.url.appending(path: "Renamed.JPG"))
        #expect(after.name == "Renamed.JPG")
        #expect(after.fileIdentifier == before.fileIdentifier)
        #expect(after.size == 10)
    }

    @Test func `attributes are read again rather than cached on the URL`() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "IMG_0001.JPG")
        try folder.write("IMG_0001.JPG", bytes: 10)
        #expect(try files.attributes(of: url).size == 10)
        try folder.write("IMG_0001.JPG", bytes: 25)
        #expect(try files.attributes(of: url).size == 25)
    }

    @Test func `a ranged read returns the range, or what's left of the file`() throws {
        let folder = try TemporaryFolder()
        try folder.write("IMG_0001.JPG", bytes: 100)
        let url = folder.url.appending(path: "IMG_0001.JPG")
        #expect(try files.read(url, range: 10 ..< 20) == Data((10 ..< 20).map(UInt8.init)))
        #expect(try files.read(url, range: 90 ..< 200) == Data((90 ..< 100).map(UInt8.init)))
        #expect(try files.read(url, range: 100 ..< 110).isEmpty)
        #expect(try files.read(url, range: 0 ..< 0).isEmpty)
        #expect(throws: POSIXError.self) { try files.read(folder.url.appending(path: "missing.JPG"), range: 0 ..< 10) }
    }

    @Test func `a read whose open a signal interrupts opens the file again, rather than failing`() async throws {
        let folder = try TemporaryFolder()
        let fifo = folder.url.appending(path: "pipe")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        // A handler without SA_RESTART, so a signal interrupts the open() a FIFO blocks in until it has a writer.
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&action.sa_mask)
        var previous = sigaction()
        sigaction(SIGUSR2, &action, &previous)
        defer { sigaction(SIGUSR2, &previous, nil) }

        let reading = Reading()
        Thread { [files] in
            // The thread starts with its creator's signal mask, which may block the signal.
            var mask = sigset_t()
            sigemptyset(&mask)
            sigaddset(&mask, SIGUSR2)
            pthread_sigmask(SIG_UNBLOCK, &mask, nil)
            reading.state.withLock { $0.thread = pthread_self() }
            var error: POSIXErrorCode?
            do {
                _ = try files.read(fifo, range: 0 ..< 1)
            } catch let failure as POSIXError {
                error = failure.code
            } catch {}
            reading.state.withLock {
                $0.error = error
                $0.ended = true
            }
        }.start()
        var signals = 0
        var writer: Int32 = -1
        let deadline = ContinuousClock.now + .seconds(10)
        while !reading.state.withLock({ $0.ended }), ContinuousClock.now < deadline {
            if let thread = reading.state.withLock({ $0.thread }), signals < 20 {
                pthread_kill(thread, SIGUSR2)
                signals += 1
            } else if signals == 20, writer < 0 {
                writer = open(fifo.path, O_RDWR | O_NONBLOCK)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        if writer >= 0 {
            close(writer)
        }
        // A FIFO refuses pread, so that error means the open went on past the signals.
        #expect(signals == 20)
        #expect(reading.state.withLock { $0.ended && $0.error == .ESPIPE })
    }

    @Test func `a volume reports its UUID, name and whether it's local`() throws {
        let folder = try TemporaryFolder()
        let volume = try files.volume(of: folder.url)
        #expect(volume.uuid?.count == 36)
        #expect(volume.name?.isEmpty == false)
        #expect(volume.isLocal)
    }
}

/// The reading thread, to signal, and the error its read ended with.
private final class Reading: @unchecked Sendable {
    struct State {
        var thread: pthread_t?
        var ended = false
        var error: POSIXErrorCode?
    }

    let state = Mutex(State())
}
