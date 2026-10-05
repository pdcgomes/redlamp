import Foundation
import MLX
import Testing
@testable import RedlampGenerative

/// diffusers' Flux2KleinInpaintPipeline in float32, on crops of two CC0 photos
/// (`REDLAMP_FLUX_INPAINT_REFERENCE`, by `research/prototypes/generative/reference_inpaint.py`),
/// with the model in `REDLAMP_FLUX_MODEL`.
enum InpaintSample {
    struct Case {
        let file: URL
        let steps: Int
        let firstTimestep: Float
        let sigmas: [Float]

        var tensors: [String: MLXArray] {
            (try? loadArrays(url: file)) ?? [:]
        }
    }

    static let reference = FluxSample.folder("REDLAMP_FLUX_INPAINT_REFERENCE")

    static let cases: [Case] = {
        guard let reference, let data = try? Data(contentsOf: reference.appending(path: "index.json")),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let file = entry["file"] as? String, let steps = entry["steps"] as? Int,
                  let first = entry["first_timestep"] as? Double, let sigmas = entry["sigmas"] as? [Double]
            else { return nil }
            return Case(
                file: reference.appending(path: file), steps: steps, firstTimestep: Float(first),
                sigmas: sigmas.map(Float.init),
            )
        }
    }()

    /// Loaded once: the transformer alone is 15.5 GB in float32.
    nonisolated(unsafe) static let float32: FluxInpainter? = FluxSample.model.flatMap {
        try? FluxInpainter(model: $0, dtype: .float32)
    }

    /// `||a - b|| / ||b||`.
    static func relativeError(_ a: MLXArray, _ b: MLXArray) -> Float {
        let a = a.asType(.float32)
        let b = b.asType(.float32)
        return ((a - b).square().sum().sqrt() / b.square().sum().sqrt()).item(Float.self)
    }

    /// The decoded image in 0…1, as the pipeline's post-processing leaves it.
    static func displayed(_ image: MLXArray) -> MLXArray {
        clip(image / 2 + 0.5, min: 0, max: 1)
    }

    /// Peak signal-to-noise ratio of `a` against `b`, both 0…1, in dB.
    static func psnr(_ a: MLXArray, _ b: MLXArray) -> Float {
        let mse = (a - b).square().mean().item(Float.self)
        return 10 * log10(1 / max(mse, 1e-12))
    }
}

@Suite(.enabled(if: FluxSample.model != nil && !InpaintSample.cases.isEmpty), .serialized)
struct FluxInpaintTests {
    @Test func `the schedule's noise levels are diffusers'`() throws {
        for sample in InpaintSample.cases {
            let tensors = sample.tensors
            let tokens = try #require(tensors["noise"]).dim(0)
            let sigmas = FlowMatchSchedule(steps: sample.steps, imageTokens: tokens).sigmas
            #expect(sigmas.count == sample.sigmas.count)
            for (ours, theirs) in zip(sigmas, sample.sigmas) {
                #expect(abs(ours - theirs) < 1e-5, "\(sigmas) against \(sample.sigmas)")
            }
            #expect(abs(sigmas[0] - sample.firstTimestep) < 1e-5)
        }
    }

    @Test func `the mask on the latents' grid is the pipeline's`() {
        // A 32 × 32 mask whose left half repaints, with a 1-pixel column across a cell centre.
        var values = [Float](repeating: 0, count: 32 * 32)
        for y in 0 ..< 32 {
            for x in 0 ..< 16 {
                values[y * 32 + x] = 1
            }
            values[y * 32 + 23] = 0.9
        }
        let latent = FluxInpainter.latentMask(MLXArray(values, [32, 32])).asArray(Float.self)
        #expect(latent == [1, 0.5, 1, 0.5])
    }

    @Test func `the VAE's latents are diffusers'`() throws {
        let inpainter = try #require(InpaintSample.float32)
        for sample in InpaintSample.cases {
            let tensors = sample.tensors
            let image = try #require(tensors["image"])
            let latents = inpainter.vae.encode(image).reshaped([-1, 128])
            let error = try InpaintSample.relativeError(latents, #require(tensors["image_latents"]))
            #expect(error < 1e-3, "\(sample.file.lastPathComponent): \(error)")
        }
    }

    @Test func `the VAE decodes the final latents to diffusers' fill`() throws {
        let inpainter = try #require(InpaintSample.float32)
        for sample in InpaintSample.cases {
            let tensors = sample.tensors
            let result = try #require(tensors["result"])
            let final = try #require(tensors["step_\(sample.steps - 1)"])
            let decoded = inpainter.vae.decode(final.reshaped([result.dim(0) / 16, result.dim(1) / 16, 128]))
            let psnr = InpaintSample.psnr(InpaintSample.displayed(decoded), result)
            #expect(psnr > 50, "\(sample.file.lastPathComponent): \(psnr) dB")
        }
    }

    @Test func `the transformer's first step is diffusers', in float32`() throws {
        let inpainter = try #require(InpaintSample.float32)
        for sample in InpaintSample.cases {
            let tensors = sample.tensors
            let velocity = try inpainter.transformer.velocity(
                image: #require(tensors["first_input"]), context: #require(tensors["embeddings"]),
                imageIDs: #require(tensors["img_ids"]), textIDs: #require(tensors["txt_ids"]),
                timestep: sample.firstTimestep,
            )
            let error = try InpaintSample.relativeError(velocity, #require(tensors["first_output"]))
            #expect(error < 2e-3, "\(sample.file.lastPathComponent): \(error)")
        }
    }

    @Test func `the token positions are the pipeline's`() throws {
        for sample in InpaintSample.cases {
            let tensors = sample.tensors
            let result = try #require(tensors["result"])
            let (rows, columns) = (result.dim(0) / 16, result.dim(1) / 16)
            let ids = concatenated([
                FluxInpainter.gridIDs(rows: rows, columns: columns, time: 0),
                FluxInpainter.gridIDs(rows: rows, columns: columns, time: 10),
            ], axis: 0)
            #expect(try InpaintSample.relativeError(ids, #require(tensors["img_ids"])) == 0)
            let text = FluxInpainter.textIDs(count: 512)
            #expect(try InpaintSample.relativeError(text, #require(tensors["txt_ids"])) == 0)
        }
    }

    @Test func `the whole fill is diffusers' from the same noise, in float32`() throws {
        let inpainter = try #require(InpaintSample.float32)
        for sample in InpaintSample.cases {
            let tensors = sample.tensors
            let (latents, image) = try inpainter.inpaint(
                image: #require(tensors["image"]), mask: #require(tensors["mask"]),
                embeddings: #require(tensors["embeddings"]), noise: #require(tensors["noise"]), steps: sample.steps,
            )
            let final = try #require(tensors["step_\(sample.steps - 1)"])
            let latentError = InpaintSample.relativeError(latents, final)
            let psnr = try InpaintSample.psnr(InpaintSample.displayed(image), #require(tensors["result"]))
            #expect(latentError < 5e-3, "\(sample.file.lastPathComponent): latents \(latentError)")
            #expect(psnr > 40, "\(sample.file.lastPathComponent): \(psnr) dB")
        }
    }
}

/// Redlamp's download (`REDLAMP_FLUX_CONVERTED`, by `research/prototypes/generative/convert_flux.py`):
/// the transformer quantised to 4 bits ahead of time, and the removal prompts encoded.
@Suite(.enabled(if: FluxSample.model != nil && FluxSample.folder("REDLAMP_FLUX_CONVERTED") != nil), .serialized)
struct FluxDownloadTests {
    @Test func `the download fills as the model quantised at load does`() throws {
        let converted = try FluxInpainter(model: #require(FluxSample.folder("REDLAMP_FLUX_CONVERTED")))
        let quantised = try FluxInpainter(model: #require(FluxSample.model), quantization: WeightQuantization(bits: 4))
        let sample = try #require(InpaintSample.cases.first)
        let tensors = sample.tensors
        func fill(_ inpainter: FluxInpainter) throws -> MLXArray {
            try inpainter.inpaint(
                image: #require(tensors["image"]), mask: #require(tensors["mask"]),
                embeddings: #require(tensors["embeddings"]), noise: #require(tensors["noise"]), steps: sample.steps,
            ).image
        }
        let psnr = try InpaintSample.psnr(
            InpaintSample.displayed(fill(converted)),
            InpaintSample.displayed(fill(quantised)),
        )
        #expect(psnr > 80, "\(psnr) dB")
    }

    @Test func `its prompts are encoded as diffusers encodes them`() throws {
        let converted = try FluxInpainter(model: #require(FluxSample.folder("REDLAMP_FLUX_CONVERTED")))
        #expect(Set(converted.prompts.keys) == ["empty", "background", "remove"])
        let reference = try FluxSample.prompts.first { $0.prompt.isEmpty }.map { try loadArrays(url: $0.file) }
        if let reference, let empty = converted.prompts["empty"], let embeddings = reference["embeddings"] {
            #expect(InpaintSample.relativeError(empty, embeddings) < 0.005)
        }
    }
}

/// How bfloat16 and 4- and 8-bit weights compare with float32 (RM-10's precision), when
/// `REDLAMP_FLUX_MEASURE` is set: time a step, peak memory, and the fill's PSNR against the float32
/// reference inside and outside the mask.
@Suite(
    .enabled(if: FluxSample.model != nil && !InpaintSample.cases.isEmpty
        && ProcessInfo.processInfo.environment["REDLAMP_FLUX_MEASURE"] != nil),
    .serialized,
)
struct FluxPrecisionMeasurements {
    @Test(arguments: ["float32", "bfloat16", "8-bit", "4-bit"])
    func `fill quality and cost by precision`(precision: String) throws {
        let model = try #require(FluxSample.model)
        Memory.clearCache()
        let before = Memory.activeMemory
        let started = Date()
        let inpainter = try FluxInpainter(
            model: model, dtype: precision == "float32" ? .float32 : .bfloat16,
            quantization: precision
                .hasSuffix("-bit") ? WeightQuantization(bits: #require(Int(precision.prefix(1)))) : nil,
        )
        let load = Date().timeIntervalSince(started)
        let weights = Double(Memory.activeMemory - before) / 1e9
        let output = ProcessInfo.processInfo.environment["REDLAMP_FLUX_MEASURE_OUT"].map(URL.init(fileURLWithPath:))
        for sample in InpaintSample.cases {
            let tensors = sample.tensors
            let mask = try #require(tensors["mask"]).expandedDimensions(axis: -1)
            let reference = try #require(tensors["result"])
            Memory.peakMemory = 0
            let resident = Memory.activeMemory
            let begun = Date()
            let (_, image) = try inpainter.inpaint(
                image: #require(tensors["image"]), mask: #require(tensors["mask"]),
                embeddings: #require(tensors["embeddings"]), noise: #require(tensors["noise"]), steps: sample.steps,
            )
            let seconds = Date().timeIntervalSince(begun)
            let shown = InpaintSample.displayed(image)
            let working = Double(Memory.peakMemory - resident) / 1e9
            if let output {
                try MLX.save(
                    arrays: ["fill": shown],
                    url: output.appending(path: "\(precision)-\(sample.file.lastPathComponent)"),
                )
            }
            let inside = InpaintSample.psnr(shown * mask, reference * mask)
            let outside = InpaintSample.psnr(shown * (1 - mask), reference * (1 - mask))
            print(
                "precision \(precision) \(sample.file.lastPathComponent): "
                    + String(
                        format: "load %.1f s, weights %.2f GB, fill %.2f s, working memory %.2f GB, ",
                        load,
                        weights,
                        seconds,
                        working,
                    )
                    + String(format: "PSNR inside the mask %.1f dB, outside %.1f dB", inside, outside),
            )
        }
    }
}

/// What a fill costs as Generative Remove runs it (RM-10 step 6), when `REDLAMP_FLUX_MEASURE` is
/// set: `FluxFiller` on the download in `REDLAMP_FLUX_CONVERTED`, shown the filled photo as its
/// reference, at the crop sizes the engine uses (512 to 1024 pixels on a side). Time and memory don't
/// depend on what the pixels show, so the photo is noise.
@Suite(
    .enabled(if: FluxSample.folder("REDLAMP_FLUX_CONVERTED") != nil
        && ProcessInfo.processInfo.environment["REDLAMP_FLUX_MEASURE"] != nil),
    .serialized,
)
struct FluxFillCostMeasurements {
    @Test func `time and memory of a fill by crop size`() throws {
        guard ProcessInfo.processInfo.environment["REDLAMP_FLUX_MEASURE"] != "phases" else { return }
        let filler = try FluxFiller(model: #require(FluxSample.folder("REDLAMP_FLUX_CONVERTED")))
        let started = Date()
        _ = try fill(filler, width: 64, height: 64, reference: false)
        print(String(
            format: "fill cost: load and a 64 px fill %.1f s, footprint %.2f GB",
            Date()
                .timeIntervalSince(started),
            Self.footprint(),
        ))
        for (width, height) in [(512, 512), (768, 768), (1024, 576), (1024, 1024)] {
            for reference in [true, false] {
                Memory.peakMemory = 0
                let begun = Date()
                _ = try fill(filler, width: width, height: height, reference: reference)
                print(String(
                    format: "fill cost: %d x %d, %@: %.1f s, peak MLX memory %.2f GB, footprint %.2f GB",
                    width, height, reference ? "with the reference" : "without one", Date().timeIntervalSince(begun),
                    Double(Memory.peakMemory) / 1e9, Self.footprint(),
                ))
            }
        }
    }

    @Test func `peak memory of each phase at 1024 pixels`() throws {
        let inpainter = try FluxInpainter(model: #require(FluxSample.folder("REDLAMP_FLUX_CONVERTED")))
        let image = MLXRandom.uniform(low: -1, high: 1, [1024, 1024, 3])
        eval(image)
        func measure(_ phase: String, _ work: () -> MLXArray) {
            Memory.clearCache()
            let resident = Memory.activeMemory
            Memory.peakMemory = 0
            let begun = Date()
            eval(work())
            print(String(
                format: "fill cost: %@ at 1024 x 1024: %.1f s, %.2f GB above the %.2f GB resident", phase,
                Date().timeIntervalSince(begun), Double(Memory.peakMemory - resident) / 1e9, Double(resident) / 1e9,
            ))
        }
        measure("VAE encode") { inpainter.vae.encode(image) }
        let latents = inpainter.vae.encode(image)
        measure("VAE decode") { inpainter.vae.decode(latents) }
        let tokens = latents.reshaped([-1, 128])
        let embeddings = try #require(inpainter.prompts["remove"])
        let ids = concatenated([
            FluxInpainter.gridIDs(rows: 64, columns: 64, time: 0), FluxInpainter.gridIDs(
                rows: 64,
                columns: 64,
                time: 10,
            ),
        ], axis: 0)
        measure("a transformer step with the reference") {
            inpainter.transformer.velocity(
                image: concatenated([tokens, tokens], axis: 0), context: embeddings, imageIDs: ids,
                textIDs: FluxInpainter.textIDs(count: embeddings.dim(0)), timestep: 1, outputs: 4096,
            )
        }
    }

    private func fill(_ filler: FluxFiller, width: Int, height: Int, reference: Bool) throws -> [Float] {
        var generator = SystemRandomNumberGenerator()
        let image = (0 ..< width * height * 3).map { _ in Float.random(in: 0 ... 1, using: &generator) }
        let mask = (0 ..< width * height).map { index -> Float in
            let x = Double(index % width) / Double(width) - 0.5, y = Double(index / width) / Double(height) - 0.5
            return x * x + y * y < 0.04 ? 1 : 0
        }
        return try filler.fill(
            image: image, reference: reference ? image : nil, mask: mask, width: width, height: height, seed: 1,
            prompt: "remove",
        ) { _ in }
    }

    /// The process's memory as Activity Monitor counts it, in GB.
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1e9 : 0
    }
}
