import Foundation

/// Library's Undo and Redo across its changes (LIB-15): culling's (`EditorModel+Culling`), the panels' (keywords,
/// metadata, collections and stacks, keywords dragged or painted onto photos, photos dropped on a collection;
/// `LibraryPanels+Changes`), the renames and moves (Move to Folder, photos dropped on a folder; `EditorModel+Files`),
/// the Put Backs (`EditorModel+PutBackUndo`) and Library Health's (`EditorModel+HealthUndo`). Each kind keeps its
/// own steps and makes and takes them back its own way, and every step has a turn in one order, given as it goes on
/// Undo and again as it goes on Redo: ⌘Z takes back the change whose turn on Undo is the latest, whatever its kind,
/// ⇧⌘Z makes again the one taken back last, and a new change of any kind ends every Redo. A change takes its turn as
/// it's asked for, so one whose batch is still running is taken back after it's made. Develop keeps its own Undo.
extension EditorModel {
    /// The kinds of Library's changes, each with an Undo of its own.
    enum LibraryUndoKind {
        case culling, panels, files, putBack, health
    }

    /// The kind of change ⌘Z takes back now; nil when there's none.
    var libraryUndoKind: LibraryUndoKind? {
        Self.latest([
            (.culling, cullingUndo.last?.turn),
            (.panels, libraryPanels.undoSteps.last?.turn),
            (.files, fileSteps.undo.last?.turn),
            (.putBack, putBackSteps.undo.last?.turn),
            (.health, healthSteps.undo.last?.turn),
        ])
    }

    /// The kind of change ⇧⌘Z makes again now; nil when there's none.
    var libraryRedoKind: LibraryUndoKind? {
        Self.latest([
            (.culling, cullingRedo.last?.turn),
            (.panels, libraryPanels.redoSteps.last?.turn),
            (.files, fileSteps.redo.last?.turn),
            (.putBack, putBackSteps.redo.last?.turn),
            (.health, healthSteps.redo.last?.turn),
        ])
    }

    /// The next turn in Library's Undo and Redo, for a step going on either.
    func nextLibraryTurn() -> Int {
        libraryUndoClock.turns += 1
        return libraryUndoClock.turns
    }

    /// A change was asked for: nothing taken back is made again, whatever its kind.
    func endLibraryRedo() {
        dropCullingRedo()
        if !libraryPanels.redoSteps.isEmpty {
            libraryPanels.redoSteps.removeAll()
        }
        fileSteps.redo.removeAll()
        putBackSteps.redo.removeAll()
        healthSteps.redo.removeAll()
    }

    private static func latest(_ kinds: [(LibraryUndoKind, Int?)]) -> LibraryUndoKind? {
        kinds.compactMap { kind, turn in turn.map { (kind, $0) } }.max { $0.1 < $1.1 }?.0
    }

    private var libraryUndoClock: LibraryUndoClock {
        if let clock = Self.libraryUndoClocks.object(forKey: self) {
            return clock
        }
        let clock = LibraryUndoClock()
        Self.libraryUndoClocks.setObject(clock, forKey: self)
        return clock
    }

    private static let libraryUndoClocks = NSMapTable<EditorModel, LibraryUndoClock>.weakToStrongObjects()
}

/// The turns given to the steps of Library's Undo and Redo, one editor's.
@MainActor
private final class LibraryUndoClock {
    var turns = 0
}
