import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The metadata and collections scenarios, small enough for every run, on a fixture of their own: their
/// counts are right, their time budgets met where speed is measured, and they leave the fixture's sidecars
/// as they found them.
struct MetadataBenchTests {
    /// Every sidecar's metadata in `folder`, by the photo's path; empty metadata as none, which a batch
    /// writes as no metadata.
    static func sidecars(in folder: URL) throws -> [String: PhotoMetadata?] {
        let store = SidecarStore()
        var found: [String: PhotoMetadata?] = [:]
        for file in try FixtureTests.files(in: folder).keys {
            let sidecar = file.hasSuffix("/" + SidecarStore.editFile) ? String(file.dropLast(10)) : file
            guard sidecar.hasSuffix(".redlamp") else { continue }
            let photo = String(sidecar.dropLast(".redlamp".count))
            found[photo] = store.load(for: folder.appending(path: photo))?.metadata.flatMap { $0.isEmpty ? nil : $0 }
        }
        return found
    }

    @Test(arguments: [
        MetadataScenario(photos: 60) as any BenchScenario, CollectionScenario(photos: 60) as any BenchScenario,
    ])
    func `each scenario counts what it should and leaves the fixture's sidecars as they were`(
        _ scenario: any BenchScenario,
    ) async throws {
        let fixture = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 200, seed: 29)).write(to: fixture.url)
        let before = try Self.sidecars(in: fixture.url)
        let context = BenchContext(fixture: fixture.url, manifest: summary.manifest, profile: .ssd)
        let report = try await BenchReport.run([scenario], in: context)
        #expect(report.failed.allSatisfy { $0.budget?.kind != .exactly }, "\(report.text)")
        #expect(report.results.count > 5)
        let after = try Self.sidecars(in: fixture.url)
        #expect(before.filter { $0.value != nil } == after.filter { $0.value != nil })
    }

    @Test(.measuresSpeed, arguments: [
        MetadataScenario(photos: 60) as any BenchScenario, CollectionScenario(photos: 60) as any BenchScenario,
    ])
    func `each scenario keeps within its time budgets`(_ scenario: any BenchScenario) async throws {
        let fixture = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 200, seed: 29)).write(to: fixture.url)
        let context = BenchContext(fixture: fixture.url, manifest: summary.manifest, profile: .ssd)
        let report = try await BenchReport.run([scenario], in: context)
        #expect(report.failed.isEmpty, "\(report.text)")
    }

    @Test func `the scenarios are registered by name`() {
        BenchScenarios.registerMetadata()
        BenchScenarios.registerCollections()
        #expect((BenchScenarios.named("metadata") as? MetadataScenario)?.photos == MetadataScenario.defaultPhotos)
        #expect((BenchScenarios.named("collections") as? CollectionScenario)?.photos == CollectionScenario
            .defaultPhotos)
    }
}
