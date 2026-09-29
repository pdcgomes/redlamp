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

    /// A fast preview for the filmstrip, usually the file's embedded thumbnail.
    func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage?
}
