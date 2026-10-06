import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampServices

/// The library's reads of capture settings and focus thumbnails give the same answers in the
/// decode service as in the app, so moving them out of the app finds the same focus stacks
/// (DATA-17).
struct FileInspectionTests {
    /// A focus stack (DSC_0750 to DSC_0757), then every raw sample.
    static let stack = DecodeRegressionTests.raws(in: "tests/fixtures/shoots/nikon-z6")
    static let files = stack + DecodeRegressionTests.fixtures

    /// A listener in this process that answers as the service does, through a real connection.
    final class Listener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()

        override init() {
            super.init()
            listener.delegate = self
            listener.resume()
        }

        func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: DecodeServiceProtocol.self)
            connection.exportedObject = DecodeService()
            connection.resume()
            return true
        }
    }

    @Test(.enabled(if: !stack.isEmpty))
    func `the stack's frames have the dates and settings a stack is found by`() {
        let captures = InProcessDecoder().captures(of: Self.stack, concurrently: false)
        #expect(captures.count == 8)
        #expect(captures.allSatisfy { $0?.date != nil && $0?.model != nil && $0?.aperture != nil })
        #expect(Set(captures.map { $0?.date }).count == 8)
        #expect(Set(captures.map { $0.map { [$0.model, $0.lens] } }).count == 1)
    }

    @Test(.enabled(if: !stack.isEmpty), arguments: [false, true])
    func `the service reads the same captures and focus thumbnails as the app`(concurrently: Bool) {
        let listener = Listener()
        let service = DecodeServiceClient(endpoint: listener.listener.endpoint)
        let local = InProcessDecoder()
        let captures = local.captures(of: Self.files, concurrently: concurrently)
        let thumbnails = local.focusThumbnails(of: Self.stack, concurrently: concurrently)
        #expect(captures.compactMap(\.self).count == Self.files.count)
        #expect(thumbnails.allSatisfy { $0?.width == GreyThumbnail.longEdge })
        withKnownIssue("the decode service doesn't read captures or thumbnails yet") {
            #expect(service.captures(of: Self.files, concurrently: concurrently) == captures)
            #expect(service.focusThumbnails(of: Self.stack, concurrently: concurrently) == thumbnails)
        }
    }

    @Test(.enabled(if: !stack.isEmpty))
    func `a file that can't be read has no capture or thumbnail, and the rest are read`() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).NEF")
        let junk = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).CR3")
        try Data(repeating: 7, count: 4096).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let listener = Listener()
        let service = DecodeServiceClient(endpoint: listener.listener.endpoint)
        let files = [missing, junk] + Self.stack.prefix(1)
        let local = InProcessDecoder().captures(of: files, concurrently: false)
        #expect(local.prefix(2).allSatisfy { $0 == nil })
        withKnownIssue("the decode service doesn't read captures yet") {
            #expect(service.captures(of: files, concurrently: false) == local)
        }
    }
}
