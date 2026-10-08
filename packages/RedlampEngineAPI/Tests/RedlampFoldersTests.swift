import Foundation
import RedlampEngineAPI
import Testing

struct RedlampFoldersTests {
    @Test func `the caches are the user's own until the process chooses others`() {
        let user = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #expect(RedlampFolders.caches.path == user.appending(path: "app.redlamp").path)
    }
}
