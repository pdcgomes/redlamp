import CoreGraphics
import Foundation

/// The only surface the UI sees of the rendering engine.
///
/// Everything crossing this boundary is a value type or an IOSurface. The concrete engine
/// lives in `RedlampEngine`, which UI modules are not allowed to import; the app's
/// composition root hands them an `EditingEngine`.
public protocol EditingEngine: AnyObject, Sendable {
    /// Decodes an image and makes it the current image. Replaces any previous one.
    func open(_ url: URL) async throws -> ImageInfo

    /// Makes `url` the current image if it is already decoded (see `prefetch`), without
    /// waiting. Returns nil when it still needs `open(_:)`.
    func openIfReady(_ url: URL) -> ImageInfo?

    /// Decodes these images in the background, most important first, so opening them is
    /// instant. Replaces the previous list; an `open` of an image no longer listed, whose
    /// decode hasn't started, throws `CancellationError`.
    func prefetch(_ urls: [URL])

    /// Schedules an interactive render. Non-blocking; if a render is in flight, the
    /// newest request replaces any pending one.
    func render(_ request: RenderRequest)

    /// The stream of rendered frames for the current image. One consumer.
    func frames() -> AsyncStream<RenderedFrame>

    /// Renders the current image at export quality.
    func renderStill(_ request: StillRequest) async throws -> CGImage

    /// Estimates a neutral white balance for the current image (the "Auto" preset).
    func autoWhiteBalance() async -> WhiteBalanceValue?

    /// The white balance that makes the area around `point` neutral. `point` is in
    /// normalised, oriented image coordinates (0...1, origin top-left).
    func whiteBalance(sampledAt point: CGPoint) async -> WhiteBalanceValue?

    /// Suggested Basic-panel values for the current image (the "Auto" tone button).
    func autoTone(for recipe: EditRecipe) async -> [ParameterID: Double]

    /// OKLab (lightness 0...1) of the current image with `recipe`'s global edit, averaged over a
    /// small area around `point` (normalised, oriented): the colours Color and Luminance Range
    /// masks select on.
    func maskColor(sampledAt point: CGPoint, recipe: EditRecipe) async -> SIMD3<Double>?

    /// Computes AI masks of the current image: one for Subject, Background or Sky, one per person
    /// for People. Throws `MaskComputationError` when the mask can't be made.
    func computeMasks(_ request: MaskRequest) async throws -> [AIMask]

    /// A quick, low-resolution Objects mask for hovering, or nil when its model isn't ready.
    func previewObjectMask(_ request: MaskRequest) async throws -> MaskBitmap?

    /// An AI mask's bitmap with its edges snapped harder to the current photo's.
    func refineMaskEdges(_ bitmap: MaskBitmap) async throws -> MaskBitmap

    /// An AI mask's bitmap with coverage under `strokes` (the Refine Edge brush) solved again per
    /// pixel from the current photo, and kept as it was everywhere else.
    func refineMaskEdges(_ bitmap: MaskBitmap, along strokes: [BrushStroke]) async throws -> MaskBitmap

    /// The AI mask kinds this device can compute now.
    func availableMaskKinds() -> Set<MaskKind>

    /// The People parts this device can compute now.
    func availablePersonParts() -> Set<PersonPart>

    /// Gets AI masks ready in the background (renders, models, embeddings) for the current photo
    /// and those opened after it, so computing one later is quicker. Called when the Masking
    /// tool opens.
    func warmUpMasks()

    /// The AI mask kinds that need a model downloaded first, and that model.
    func modelNeeded(for kind: MaskKind) async -> ModelInfo?

    /// The downloadable models and their state.
    func models() async -> [ModelInfo]

    /// Downloads a model (`progress` gets 0...1 from any thread).
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws

    func removeModel(_ id: String) async throws

    /// A fast preview for the filmstrip, usually the file's embedded thumbnail.
    func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage?

    /// The same preview, decoded on the calling thread, which it blocks: for callers that
    /// schedule decodes themselves (the filmstrip's thumbnail loader). Never call it on the
    /// main thread.
    func decodeThumbnail(for url: URL, maxPixelSize: Int) -> CGImage?

    /// Makes a Base Look renderable. Edits reference it by id and version, and pin its
    /// look table by content hash; built-in looks need no registration. Registering the
    /// same look again is cheap. Edits whose look isn't registered render without it.
    func registerBaseLook(_ look: BaseLookDefinition)

    /// Whether the engine can render `reference` exactly as pinned.
    func canRender(_ reference: BaseLookReference) -> Bool

    /// The open photo's embedded camera profile look (`ImageInfo.embeddedBaseLook`), for
    /// keeping with the installed looks once an edit uses it.
    func embeddedBaseLook() -> BaseLookDefinition?

    /// The open photo's straight edges, for automatic Upright.
    func detectLines() async -> [DetectedLine]

    /// Where `spot` of the open photo should copy from: the nearby circle that matches its
    /// surroundings best, clear of the spot itself. `recipe`'s spots apply first. Nil when none fits.
    func retouchSource(for spot: RetouchSpot, recipe: EditRecipe) async -> ImagePoint?

    /// The focus stack document at `url`, merged now or read from the cache, developed with the
    /// default edit within `maxLongEdge`. `progress` gets 0 ... 1 from any thread. Opening the
    /// document afterwards shows this merge, even if it changed since it was last opened.
    func focusStack(
        at url: URL, maxLongEdge: Int, progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> FocusStackPreview
}

public extension EditingEngine {
    func warmUpMasks() {}

    func availablePersonParts() -> Set<PersonPart> {
        Set(PersonPart.allCases)
    }

    func decodeThumbnail(for _: URL, maxPixelSize _: Int) -> CGImage? {
        nil
    }

    func embeddedBaseLook() -> BaseLookDefinition? {
        nil
    }

    func detectLines() async -> [DetectedLine] {
        []
    }

    func retouchSource(for _: RetouchSpot, recipe _: EditRecipe) async -> ImagePoint? {
        nil
    }
}
