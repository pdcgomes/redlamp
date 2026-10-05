import Foundation
import MLX
import RedlampEngineAPI

/// Generative fill on FLUX.2 [klein] 4B (RM-10), which the app and the CLI register with the engine
/// (`RedlampEngine.register(generativeFiller:)`). The model loads on the first fill and stays loaded
/// until `unload`; one fill runs at a time.
public final class FluxFiller: GenerativeFiller, @unchecked Sendable {
    public enum FillerError: Error, CustomStringConvertible {
        case missingPrompt(String)

        public var description: String {
            switch self {
            case let .missingPrompt(name): "The model has no prompt called \(name)."
            }
        }
    }

    /// Steps a fill takes: the distilled model's own.
    public static let steps = 4

    private let directory: URL
    private let lock = NSLock()
    private var inpainter: FluxInpainter?

    /// From Redlamp's download of the model (`convert_flux.py`), which carries its prompts.
    public init(model directory: URL) {
        self.directory = directory
    }

    public func fill(
        image: [Float], reference: [Float]?, mask: [Float], width: Int, height: Int, seed: Int, prompt: String,
        progress: @escaping @Sendable (Double) -> Void,
    ) throws -> [Float] {
        try lock.withLock {
            let inpainter = try inpainter ?? FluxInpainter(model: directory)
            self.inpainter = inpainter
            guard let embeddings = inpainter.prompts[prompt] else { throw FillerError.missingPrompt(prompt) }
            let steps = Self.steps
            let (_, filled) = inpainter.inpaint(
                image: MLXArray(image, [height, width, 3]) * 2 - 1, mask: MLXArray(mask, [height, width]),
                embeddings: embeddings, noise: FluxInpainter.noise(width: width, height: height, seed: UInt64(seed)),
                steps: steps, references: reference.map { [MLXArray($0, [height, width, 3]) * 2 - 1] } ?? [],
            ) { step in
                progress(Double(step) / Double(steps + 1))
            }
            let shown = clip(filled / 2 + 0.5, min: 0, max: 1).asArray(Float.self)
            Memory.clearCache()
            progress(1)
            return shown
        }
    }

    public func unload() {
        lock.withLock { inpainter = nil }
        Memory.clearCache()
    }
}
