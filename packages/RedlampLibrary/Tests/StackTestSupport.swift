import Foundation
@testable import RedlampLibrary

/// Photos to find stacks among, as the column store and the index's names hold them, numbered from 1
/// in the order they're added.
struct StackLibrary {
    struct Photo {
        var id: Int64
        var folder: Int64
        var name: String
        /// Seconds since 1970.
        var captured: Double?
        var camera: Int64?
        var lens: Int64?
        var iso: Double?
        var aperture: Double?
        var shutter: Double?
        var focal: Double?
    }

    private(set) var photos: [Photo] = []

    /// Adds a photo shot with the settings given, and returns its ID.
    @discardableResult
    mutating func add(
        _ name: String, folder: Int64 = 1, at captured: Double?, camera: Int64? = 1, lens: Int64? = 1,
        iso: Double? = 100, aperture: Double? = 2.8, shutter: Double? = 1.0 / 250, focal: Double? = 35,
    ) -> Int64 {
        let id = Int64(photos.count + 1)
        photos.append(Photo(
            id: id, folder: folder, name: name, captured: captured, camera: camera, lens: lens, iso: iso,
            aperture: aperture, shutter: shutter, focal: focal,
        ))
        return id
    }

    /// A raw and its JPEG, shot together, and their IDs.
    @discardableResult
    mutating func addPair(_ base: String, folder: Int64 = 1, at captured: Double?, shutter: Double? = 1.0 / 250)
        -> (raw: Int64, jpeg: Int64) {
        (
            add(base + ".CR3", folder: folder, at: captured, shutter: shutter),
            add(base + ".JPG", folder: folder, at: captured, shutter: shutter),
        )
    }

    var store: ColumnStore {
        ColumnStore(rows: photos.map { photo in
            ColumnStore.Row(HotColumns(
                id: photo.id, folder: photo.folder, captured: photo.captured, camera: photo.camera, lens: photo.lens,
                rating: 0, flag: 0, label: 0, marked: false, edited: false, iso: photo.iso, aperture: photo.aperture,
                focal: photo.focal,
                kind: PhotoRecord.Kind(pathExtension: (photo.name as NSString).pathExtension).rawValue,
                name: photo.name,
            ), shutter: photo.shutter)
        })
    }

    var names: StackNames {
        var names = StackNames()
        for photo in photos {
            names[photo.id] = photo.name
        }
        return names
    }

    func find(_ choices: StackChoices = StackChoices()) -> Stacks {
        StackFinder.find(in: store, names: names, choices: choices)
    }

    /// Every photo in capture order, as All Photographs lists them.
    var list: PhotoList {
        PhotoList(source: .allPhotographs, sort: QuerySort(), ids: store.ids(sortedBy: QuerySort()))
    }

    func photo(_ id: Int64) -> Photo {
        photos[Int(id) - 1]
    }
}

extension Stacks {
    /// The stacks of `kind`, each by its photos.
    func photos(_ kind: Stack.Kind) -> [[Int64]] {
        filter { $0.kind == kind }.map(\.photos)
    }
}
