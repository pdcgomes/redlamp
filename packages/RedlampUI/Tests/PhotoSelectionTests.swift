import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Several photos selected in the filmstrip: ⌘ adds or takes away, ⇧ selects a range, a plain
/// click or the next photo selects one.
@MainActor
struct PhotoSelectionTests {
    @Test func `clicks select several photos, the clicked one active`() {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = EditorModel(engine: StubEngine())
        let photos = ["A", "B", "C", "D", "E"].map { folder.appending(path: "\($0).ARW") }
        photos.forEach { model.library.insert(LibraryItem(url: $0)) }

        model.click(photos[1])
        #expect(model.selectedPhotos == [photos[1]] && !model.isMultiSelecting)
        model.click(photos[3], toggling: true)
        #expect(model.selectedPhotos == [photos[1], photos[3]])
        #expect(model.selection == photos[3], "the clicked photo is active")
        model.click(photos[0], toggling: true)
        #expect(model.selectedPhotos == [photos[0], photos[1], photos[3]], "in filmstrip order")

        model.click(photos[0], toggling: true)
        #expect(model.selectedPhotos == [photos[1], photos[3]])
        #expect(model.selection == photos[3], "taking away another photo keeps the active one")
        model.click(photos[3], toggling: true)
        #expect(model.selectedPhotos == [photos[1]])
        #expect(model.selection == photos[1], "taking away the active photo makes another active")
        model.click(photos[1], toggling: true)
        #expect(model.selectedPhotos == [photos[1]], "the last photo stays selected")

        model.click(photos[4], extending: true)
        #expect(model.selectedPhotos == Array(photos[1 ... 4]))
        #expect(model.selection == photos[4])

        model.deselectOtherPhotos()
        #expect(model.selectedPhotos == [photos[4]])
        model.selectAllPhotos()
        #expect(model.selectedPhotos == photos && model.selection == photos[4])
        model.selectPrevious()
        #expect(model.selectedPhotos == [photos[3]], "moving to another photo selects only it")
        model.click(photos[3])
        #expect(model.selectedPhotos == [photos[3]])
    }
}
