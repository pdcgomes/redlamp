import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Other apps' metadata in the app (LIB-24): writing `.xmp` off by default and turned on from Settings
/// only once that's confirmed.
@MainActor
struct LibraryOtherAppsTests {
    private typealias Folder = CullingTests.IndexedFolder

    private static func xmp(of photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// What the photo's `.xmp` holds, as other apps read it; nil without one.
    private static func fields(of photo: URL) -> XMPFields? {
        (try? Data(contentsOf: xmp(of: photo))).flatMap { XMPSource(xmp: $0) }?.fields
    }

    @Test func `writing .xmp is off by default, and Settings turns it on and off only once that's confirmed`(
    ) async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 3)
        let service = try #require(folder.service)
        let core = try #require(service.core)
        #expect(service.xmpSettings == XMPSettings(writes: false))

        let settings = LibrarySettingsModel(library: service)
        await settings.countPhotos()
        settings.ask(writes: true)
        #expect(settings.confirming == .turningOn)
        #expect(settings.message(.turningOn).contains("The 3 photos already in the library are left as they are"))
        #expect(try await core.xmp.settings().writes == false, "nothing changes until it's confirmed")
        settings.cancel()
        #expect(settings.confirming == nil && service.xmpSettings?.writes == false)

        settings.ask(writes: true)
        await settings.confirm()?.value
        #expect(try await core.xmp.settings().writes && service.xmpSettings?.writes == true)
        #expect(folder.photos.allSatisfy { Self.fields(of: $0) == nil }, "the photos already there are left alone")

        await settings.set(labels: .bridge).value
        await settings.set(urgency: true).value
        #expect(try await core.xmp.settings() == XMPSettings(
            writes: true, conventions: XMPConventions(labels: .bridge, urgency: true),
        ))
        settings.ask(writes: false)
        #expect(settings.confirming == .turningOff && settings.message(.turningOff).contains("stay beside your photos"))
        await settings.confirm()?.value
        #expect(try await core.xmp.settings().writes == false && !core.xmpSettings.writes)
    }
}
