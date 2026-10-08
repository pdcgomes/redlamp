import Foundation
import RedlampLibrary

/// A source's summary through the library (LIB-23, LIB-41): the days its photos were taken on, its cameras and
/// lenses, its ISO, shutter and aperture ranges, and its pairs and stacks, from the column store and the stacks
/// found in it, off the main thread.
extension LibraryService {
    /// `source`'s summary as the library has it now, of just the photos `only` names when it's given; nil while
    /// the library isn't open.
    func summary(of source: PhotoSource, only: Set<Int64>? = nil) async -> SourceSummary? {
        guard let core else { return nil }
        let (index, engine) = (core.index, core.engine)
        return await Task.detached(priority: .userInitiated) { () -> SourceSummary? in
            guard var list = try? await engine.list(source), let store = engine.store,
                  let stacks = try? await StackFinder.find(in: index, store: store),
                  let grouping = try? await engine.grouping(stacks: stacks)
            else { return nil }
            if let only {
                list = PhotoList(source: source, sort: list.sort, ids: list.ids.filter(only.contains))
            }
            return try? grouping.summary(of: list)
        }.value
    }

    // MARK: - For the regression suite

    /// Tells the library's open lists that the rows of `ids` changed, as Redlamp's own writes do.
    @_spi(Harness) public func rowsChanged(_ ids: [Int64]) {
        photosChanged(ids)
    }
}
