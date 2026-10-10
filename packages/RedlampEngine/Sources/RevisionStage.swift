import Foundation
import RedlampEngineAPI

/// An edit made before its photo's raw stages last changed (`RawRevision`) renders from a variant:
/// the photo's decoded image built again at the edit's revision, with its own pyramid and maps
/// (`SessionBuilder.variant(of:at:)`). The variant stands in for the photo for that edit
/// everywhere after it: its retouched copies, Detail, the develop kernel, its masks and Auto.
///
/// A photo nothing clipped in builds the same pyramid at every revision and serves every edit, so
/// it has no variants. Its state is behind `lock`: renders ask on the render queue, Auto elsewhere.
final class RevisionStage: @unchecked Sendable {
    private let builder: SessionBuilder
    private let lock = NSLock()
    private var variants: [ImageSession] = []
    private var builds = 0

    init(builder: SessionBuilder) {
        self.builder = builder
    }

    /// The variants kept, for tests.
    var keptVariants: [ImageSession] {
        lock.withLock { variants }
    }

    /// Variants built so far, for tests.
    var variantsBuilt: Int {
        lock.withLock { builds }
    }

    /// The session `recipe` renders from: `session` when it serves the edit's raw revision, otherwise
    /// the photo or its variant at that revision, built the first time it's asked for.
    func session(for recipe: EditRecipe, base session: ImageSession) throws -> ImageSession {
        let revision = recipe.rawRevision
        guard !session.serves(revision) else { return session }
        let photo = session.photo
        guard !photo.serves(revision) else { return photo }
        lock.lock()
        defer { lock.unlock() }
        if let variant = variants.first(where: { $0.photo === photo && $0.rawRevision == revision }) {
            return variant
        }
        guard let variant = try builder.variant(of: photo, at: revision) else { return photo }
        variants.append(variant)
        builds += 1
        return variant
    }

    /// Lets go of the variants of photos other than `session`'s; of every one when it's nil.
    func keepOnly(_ session: ImageSession?) {
        let photo = session?.photo
        lock.withLock {
            variants.removeAll { $0.photo !== photo }
        }
    }

    /// Lets go of the variants of `session`'s photo that none of `recipes` renders from, returning
    /// them so the stages that worked on them can let go too.
    func keep(for recipes: [EditRecipe], of session: ImageSession) -> [ImageSession] {
        let photo = session.photo
        let revisions = Set(recipes.map(\.rawRevision))
        return lock.withLock {
            let dropped = variants.filter { $0.photo === photo && !revisions.contains($0.rawRevision) }
            variants.removeAll { $0.photo === photo && !revisions.contains($0.rawRevision) }
            return dropped
        }
    }
}
