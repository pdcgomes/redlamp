import Foundation
import RedlampDocument
import RedlampEngineAPI

public extension EditorModel {
    /// Looks for focus stacks among a folder's photos in the background.
    internal func detectStacks(in urls: [URL], folder: URL) {
        Task {
            let found = await Task.detached(priority: .utility) {
                StackDetector.suggestions(in: urls)
            }.value
            guard self.folder == folder else { return }
            stackSuggestions = found
        }
    }

    /// Saves the stack as a document beside its frames, adds it to the library and opens the
    /// Stack workspace on it, which merges it.
    func mergeStack(_ suggestion: StackSuggestion) {
        let url = suggestion.documentURL()
        do {
            try suggestion.save(to: url)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        stackSuggestions.removeAll { $0 == suggestion }
        library.insert(LibraryItem(url: url))
        openStackWorkspace(url)
    }

    func dismissStack(_ suggestion: StackSuggestion) {
        stackSuggestions.removeAll { $0 == suggestion }
    }

    func openStackWorkspace(_ url: URL) {
        saveNow()
        stackWorkspace = StackWorkspaceModel(documentURL: url, engine: engine)
    }

    /// Closes the workspace and develops the merged photo, reopening it if it was showing.
    func finishStackWorkspace() {
        guard let url = stackWorkspace?.documentURL else { return }
        stackWorkspace = nil
        if selection == url {
            selection = nil
        }
        select(url)
    }
}
