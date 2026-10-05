import Foundation

/// What generative fill runs on (RM-10): an image model the app hands the engine
/// (`RedlampGenerative`'s FLUX.2 [klein] 4B), so the engine itself, and the iPad and iPhone builds
/// that share it, never link one.
public protocol GenerativeFiller: AnyObject, Sendable {
    /// Repaints `mask`'s area (`width` × `height`, 1 repaints) of `image` (RGB, `width` × `height`
    /// × 3, 0…1, sRGB-encoded; each side a multiple of 16) from `seed`, guided by the prompt named
    /// `prompt` and, when given, a `reference` image in the same form for the model to look at.
    /// `progress` hears 0…1. Returns the image in the same form.
    func fill(
        image: [Float], reference: [Float]?, mask: [Float], width: Int, height: Int, seed: Int, prompt: String,
        progress: @escaping @Sendable (Double) -> Void,
    ) throws -> [Float]

    /// Frees the model's memory until it's next needed.
    func unload()
}

/// What the model is shown beside the area it repaints.
public enum GenerativeFillReference: String, Sendable, Hashable, CaseIterable, Codable {
    /// The photo as it is, the thing to remove included (diffusers' inpainting pipeline does this).
    case photo
    /// The photo with the spot filled from around it (content-aware Remove).
    case filled
    /// The same, blurred inside the spot, so the model takes its colours but not its texture.
    case softened
    /// Nothing: the model sees the photo only through what's kept outside the area.
    case none
}

/// How a Remove spot is filled generatively; nil values take Generative Remove's own.
public struct GenerativeFillOptions: Sendable, Hashable {
    /// The prompt's name, from those the model's download carries.
    public var prompt: String?
    public var reference: GenerativeFillReference?

    public init(prompt: String? = nil, reference: GenerativeFillReference? = nil) {
        self.prompt = prompt
        self.reference = reference
    }
}

/// Makes a filler from the model's folder.
public typealias GenerativeFillerFactory = @Sendable (URL) throws -> any GenerativeFiller

/// Whether a Remove spot can be filled generatively here (RM-10).
public enum GenerativeFillAvailability: Sendable, Hashable {
    /// This build has no generative model (the CLI without it, iPad and iPhone), or the model
    /// isn't offered on this Mac (too little memory, or not published yet).
    case unavailable(String)
    /// The model is offered but not downloaded yet.
    case needsModel(ModelInfo)
    case ready
}
