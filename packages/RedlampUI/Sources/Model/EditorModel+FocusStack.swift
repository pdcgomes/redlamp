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

    /// Saves the stack as a document beside its frames and opens it; opening merges it.
    func mergeStack(_ suggestion: StackSuggestion) {
        guard let folder else { return }
        let url = suggestion.documentURL()
        do {
            try suggestion.save(to: url)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        stackSuggestions.removeAll { $0 == suggestion }
        openFolder(folder, select: url)
    }

    func dismissStack(_ suggestion: StackSuggestion) {
        stackSuggestions.removeAll { $0 == suggestion }
    }
}
