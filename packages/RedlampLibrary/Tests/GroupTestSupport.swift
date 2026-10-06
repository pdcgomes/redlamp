import Foundation
import RedlampDocument
@testable import RedlampLibrary

/// Photos to group, as the column store, the index's small tables and its names hold them, numbered
/// from 1 in the order they're added.
struct GroupLibrary {
    struct Photo {
        var id: Int64
        var folder: Int64
        var name: String
        /// Seconds since 1970, of the camera's clock read as UTC.
        var captured: Double?
        var camera: Int64?
        var lens: Int64?
        var flag: PhotoFlag?
        var iso: Double?
        var aperture: Double?
        var shutter: Double?
        var width: Int?
        var height: Int?
    }

    private(set) var photos: [Photo] = []
    var folders: [Int64: String] = [1: "/Volumes/Test/Photos/Shoot"]
    var cameras: [Int64: String] = [1: "Nikon Z 6", 2: "Fujifilm X-T5"]
    var lenses: [Int64: String] = [1: "NIKKOR Z 24-70mm f/4 S", 2: "XF35mmF1.4 R"]
    var choices = StackChoices()

    /// Midnight on 14 June 2025, by the camera's clock.
    static let june14 = Double(QueryCalendar.days(2025, 6, 14)) * 86400

    /// Adds a photo and returns its ID.
    @discardableResult
    mutating func add(
        _ name: String, at captured: Double?, folder: Int64 = 1, camera: Int64? = 1, lens: Int64? = 1,
        flag: PhotoFlag? = nil, iso: Double? = 400, aperture: Double? = 4, shutter: Double? = 1.0 / 250,
        width: Int? = 6000, height: Int? = 4000,
    ) -> Int64 {
        let id = Int64(photos.count + 1)
        photos.append(Photo(
            id: id, folder: folder, name: name, captured: captured, camera: camera, lens: lens, flag: flag, iso: iso,
            aperture: aperture, shutter: shutter, width: width, height: height,
        ))
        return id
    }

    /// `count` photos from `start`, each `gap(shot)` seconds after the one before, named from `prefix`.
    @discardableResult
    mutating func shoot(
        _ count: Int, from start: Double, prefix: String = "DSC_", camera: Int64? = 1,
        gap: (Int) -> Double,
    ) -> [Int64] {
        var time = start
        var ids: [Int64] = []
        for shot in 0 ..< count {
            ids.append(add(prefix + String(format: "%04d", photos.count + 1) + ".NEF", at: time, camera: camera))
            time += gap(shot)
        }
        return ids
    }

    func photo(_ id: Int64) -> Photo {
        photos[Int(id) - 1]
    }

    var store: ColumnStore {
        ColumnStore(rows: photos.map { photo in
            ColumnStore.Row(
                HotColumns(
                    id: photo.id, folder: photo.folder, captured: photo.captured, camera: photo.camera,
                    lens: photo.lens,
                    rating: 0, flag: PhotoRecord.code(for: photo.flag), label: 0, marked: false, edited: false,
                    iso: photo.iso, aperture: photo.aperture, focal: 50,
                    kind: PhotoRecord.Kind(pathExtension: (photo.name as NSString).pathExtension).rawValue,
                    name: photo.name,
                ),
                shutter: photo.shutter, width: photo.width, height: photo.height,
            )
        })
    }

    var names: QueryNames {
        QueryNames(folders: folders, cameras: cameras, lenses: lenses)
    }

    var stackNames: StackNames {
        var names = StackNames()
        for photo in photos {
            names[photo.id] = photo.name
        }
        return names
    }

    var orientations: PhotoOrientations {
        var orientations = PhotoOrientations()
        for photo in photos {
            orientations[photo.id] = PhotoOrientation(width: photo.width, height: photo.height)
        }
        return orientations
    }

    func grouping() -> LibraryGrouping {
        let store = store
        return LibraryGrouping(
            store: store, names: names, stacks: StackFinder.find(in: store, names: stackNames, choices: choices),
            orientations: orientations,
        )
    }

    /// Every photo in capture order, as All Photographs lists them.
    var list: PhotoList {
        PhotoList(source: .allPhotographs, sort: QuerySort(), ids: store.ids(sortedBy: QuerySort()))
    }
}

extension PhotoGroups {
    /// Each group's photos, in order.
    var photoSets: [[Int64]] {
        map { Array($0.photos) }
    }
}
