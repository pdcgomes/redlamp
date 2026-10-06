import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import RedlampMasking

struct InferenceTests {
    @Test func `stopping waits for the prediction running`() {
        let inference = Inference()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = Mutex(false)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? inference.run {
                started.signal()
                release.wait()
                finished.withLock { $0 = true }
            }
        }
        started.wait()
        #expect(inference.isRunning)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }
        #expect(inference.stop(waitingAtMost: 30))
        #expect(finished.withLock { $0 })
        #expect(!inference.isRunning)
    }

    @Test func `no prediction starts once stopped`() {
        let inference = Inference()
        #expect(inference.stop(waitingAtMost: 0))
        let ran = Mutex(false)
        #expect(throws: CancellationError.self) {
            try inference.run { ran.withLock { $0 = true } }
        }
        #expect(!ran.withLock { $0 })
    }

    /// A prediction that doesn't return in time doesn't keep the app from quitting.
    @Test func `stopping gives up after its timeout`() {
        let inference = Inference()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? inference.run {
                started.signal()
                release.wait()
            }
        }
        started.wait()
        #expect(!inference.stop(waitingAtMost: 0.1))
        release.signal()
    }

    /// So the app can stop them all before it exits.
    @Test func `every model loads and predicts through Inference`() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let files = try #require(FileManager.default.subpaths(atPath: sources.path)).filter { $0.hasSuffix(".swift") }
        #expect(files.contains("SAM3Concepts.swift"))
        for file in files where file != "Inference.swift" {
            let source = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            for call in [".prediction(", ".predictions(", "MLModel(contentsOf"] {
                #expect(!source.contains(call), "\(file) calls \(call)…) itself")
            }
        }
    }

    /// Quitting while SAM 3 decodes the Landscape classes, as the app does after `stop`: exit()
    /// then destroys Metal Performance Shaders Graph's statics, and a decoder still running
    /// crashes in MPSGraphOSLog.
    @Test(.enabled(if: InferenceTests.sam3 != nil && !InferenceTests.isSandboxed))
    func `quitting while SAM 3 decodes Landscape exits cleanly`() async {
        await #expect(processExitsWith: .success) {
            // Registered before those statics are made, so it runs after their destructors: exit()
            // stays under way for a while, as it does waiting on CoreAnalytics on a busy Mac.
            atexit { usleep(300_000) }
            let sam3 = try #require(InferenceTests.sam3)
            let model = try SAM3Concepts(manifest: sam3.manifest, directory: sam3.directory)
            let features = try model.features(of: InferenceTests.photo())
            Task.detached { _ = try? model.classes(features) }
            let deadline = Date(timeIntervalSinceNow: 60)
            while !Inference.shared.isRunning, Date() < deadline {
                usleep(1000)
            }
            try #require(Inference.shared.stop(waitingAtMost: 30))
            exit(0)
        }
    }

    /// Whether this process runs in a sandbox, where XCTest runs no exit tests (an agent's shell
    /// in Cursor is one).
    static let isSandboxed: Bool = {
        typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        guard let check = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return false }
        return unsafeBitCast(check, to: Check.self)(getpid(), nil, 0) != 0
    }()

    static let sam3: (manifest: ModelManifest, directory: URL)? = {
        guard let manifest = ModelCatalog.manifest("sam3") else { return nil }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Redlamp/Models/\(manifest.id)/\(manifest.version)")
        return FileManager.default.fileExists(atPath: directory.path) ? (manifest, directory) : nil
    }()

    /// Sky over a field.
    static func photo() throws -> CGImage {
        let (width, height) = (1008, 672)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(CGColor(srgbRed: 0.45, green: 0.65, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return try #require(context.makeImage())
    }
}
