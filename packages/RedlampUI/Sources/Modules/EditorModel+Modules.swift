import Foundation

/// The Library and Develop modules of the one window (LIB-13, DEC-49). Both show the same source, selection
/// and active photo; switching shows one module's views and hides the other's, building and reading nothing,
/// so it's on screen within a frame. Develop keeps the photo it has open while Library is shown; when Library
/// made another photo active, Develop opens that one as it's shown, from its preview until its render lands.
public extension EditorModel {
    func showModule(_ next: AppModule) {
        guard next != module else { return }
        previousModule = module
        module = next
        if next == .develop {
            openActivePhoto()
        }
    }

    /// G, E, C and N: the Library module, showing the grid, the loupe, Compare or Survey.
    func showLibrary(_ view: LibraryView) {
        libraryView = view
        showModule(.library)
    }

    /// ⌥⌘↑: the module shown before this one.
    func showPreviousModule() {
        guard let previousModule else { return }
        showModule(previousModule)
    }

    /// The modules' keys, and D, R, Q and ⇧W from Library: the active photo in Develop with that tool, as in
    /// Lightroom Classic. Nil for every other action.
    internal func performModuleShortcut(_ action: ShortcutAction) -> Bool? {
        if let tool = developTool(for: action) {
            activeTool = tool
            showModule(.develop)
            return true
        }
        switch action {
        case .libraryModule: showModule(.library)
        case .developModule: showModule(.develop)
        case .previousModule:
            guard previousModule != nil else { return false }
            showPreviousModule()
        case .gridView: showLibrary(.grid)
        case .loupeView:
            guard selection != nil else { return false }
            showLibrary(.loupe)
        case .compareView where module == .library && libraryView == .compare:
            return selection != nil
        case .compareView: return showCompare()
        case .surveyView: return showSurvey()
        default: return nil
        }
        return true
    }

    /// Whether `performModuleShortcut` would do something now; nil for the actions it leaves alone.
    internal func canPerformModuleShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .libraryModule, .developModule, .gridView: true
        case .previousModule: previousModule != nil
        case .loupeView, .compareView, .surveyView: selection != nil
        case .cropTool where module == .library, .healTool where module == .library: selection != nil
        default: nil
        }
    }

    /// The tool D opens Develop on, from either module, and R, Q and ⇧W from Library.
    private func developTool(for action: ShortcutAction) -> EditTool? {
        switch action {
        case .editTool: .edit
        case .maskingTool where module == .library: .masking
        case .cropTool where module == .library: .crop
        case .healTool where module == .library: .heal
        default: nil
        }
    }
}
