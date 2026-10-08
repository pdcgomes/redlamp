import Darwin
import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The test run's own folder, which goes when the run ends: Redlamp's caches move into it as the test
/// bundle loads (`TestRun.c`), so nothing a test makes reaches the owner's.
enum TestRun {
    static let folder = FileManager.default.temporaryDirectory
        .appending(path: "redlamp-tests-\(getpid())", directoryHint: .isDirectory)
}

/// Moves Redlamp's caches into the test run's folder. The owner's model compiles are cloned into it,
/// taking no space and no time, so the models aren't compiled again on every run; a model compiled
/// during the run is compiled into the run's own.
@_cdecl("RedlampTestRunBegin")
func testRunBegin() {
    let owners = RedlampFolders.caches
    let caches = TestRun.folder.appending(path: "Caches", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: TestRun.folder)
    try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    RedlampFolders.caches = caches
    _ = clonefile(owners.appending(path: "CompiledModels").path, caches.appending(path: "CompiledModels").path, 0)
    atexit { try? FileManager.default.removeItem(at: TestRun.folder) }
}

@MainActor
struct TestRunTests {
    @Test func `an editor's thumbnails are kept in the test run's own folder`() {
        let caches = TestRun.folder.appending(path: "Caches")
        #expect(RedlampFolders.caches.path == caches.path)
        #expect(EditorModel(engine: StubEngine()).thumbnailLoader.packs.directory.path
            == caches.appending(path: "Thumbnails").path)
    }
}
