import Foundation
import Testing
@testable import RedlampLibrary

struct LibraryPathsTests {
    @Test func `everything the library keeps sits under its root`() {
        let root = URL(fileURLWithPath: "/tmp/library-paths", isDirectory: true)
        let paths = LibraryPaths(root: root)
        for url in [paths.index, paths.snapshots, paths.store, paths.sidecars, paths.definitions] {
            #expect(url.path.hasPrefix(root.path + "/"))
        }
    }

    @Test func `the standard library lives in Redlamp's Application Support folder`() {
        #expect(LibraryPaths.standard.root.path.hasSuffix("Application Support/Redlamp/Library"))
    }
}
