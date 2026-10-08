import Foundation
import Synchronization

/// Where Redlamp keeps what it makes for itself.
public enum RedlampFolders {
    private static let chosenCaches = Mutex<URL?>(nil)

    /// The caches: thumbnails, focus stack merges, model compiles and embeddings, all of which can be
    /// made again. `~/Library/Caches/app.redlamp`, shared by the app and the command-line tool, unless
    /// the process sets another before anything reads it, as a test run does to keep what it makes
    /// out of the user's.
    public static var caches: URL {
        get {
            chosenCaches.withLock { $0 } ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "app.redlamp", directoryHint: .isDirectory)
        }
        set {
            chosenCaches.withLock { $0 = newValue }
        }
    }
}
