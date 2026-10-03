import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// The downloaded samples the evaluation reads: tests/fixtures/raw and the shoots
/// `scripts/fetch-shoot-fixtures.sh` downloads.
enum DustSamples {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "tests/fixtures")

    static func files(_ folder: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root.appending(path: folder), includingPropertiesForKeys: nil,
        )) ?? []
        return urls.filter(SupportedFormats.isRaw).sorted { $0.path < $1.path }
    }

    /// Varied scenes, one frame per camera.
    static let scenes = files("raw") + files("shoots/scenes")
    /// One camera on a tripod: the same scene eight times (the last two in smaller crop modes).
    static let series = files("shoots/nikon-z6")

    /// Specks already in the photos, checked by eye, as shown (0...1): finding them isn't a false
    /// find. The Z 6 has dust of its own, a soft round shadow in the same place in every frame,
    /// and the 5D Mark IV's lamp has particles on its glass.
    static let known: [String: [SIMD2<Double>]] = {
        var known = ["Canon_EOS-5D-Mark-IV_B13A0729.CR2": [
            SIMD2(0.792, 0.161), SIMD2(0.798, 0.140), SIMD2(0.795, 0.210), SIMD2(0.721, 0.256),
        ]]
        for frame in 750 ... 755 {
            known["DSC_0\(frame).NEF"] = [SIMD2(0.227, 0.218)]
        }
        return known
    }()
}

/// Dust detection measured on real photos with realistic dust added (RM-02): specks of several
/// sizes and strengths, some of them fibres, darkening every channel alike, at the same sensor
/// places in every frame. Without the downloaded samples it's skipped.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil && DustSamples.scenes.count >= 5))
struct DustEvaluationTests {
    // MARK: - Synthetic dust

    struct Speck {
        /// Normalised sensor coordinates (before orientation).
        var center: SIMD2<Double>
        /// The shadow's width (a Gaussian's), in the sensor's pixels.
        var width: Double
        var depth: Double
        /// 1 for a round speck; a fibre is longer than it's wide.
        var aspect: Double
        var angle: Double
    }

    /// Dust as a sensor of about 24 to 45 megapixels shows it from f/8 to f/16: widths log-uniform
    /// from 3 to 12 pixels (shadows 10 to 40 across) times `scale`, darkening 4% to 20%, one in
    /// five a fibre.
    static func pattern(seed: UInt64, count: Int = 10, scale: Double = 1) -> [Speck] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func random() -> Double {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return Double((state &* 2_685_821_657_736_338_717) >> 11) / Double(1 << 53)
        }
        return (0 ..< count).map { _ in
            let fibre = random() < 0.2
            return Speck(
                center: SIMD2(0.05 + 0.9 * random(), 0.05 + 0.9 * random()),
                width: scale * exp(log(3.0) + random() * log(4.0)),
                depth: exp(log(0.04) + random() * log(5)),
                aspect: fibre ? 3 + 2 * random() : 1,
                angle: random() * .pi,
            )
        }
    }

    /// The image with each speck's shadow multiplied into its raw data, above the black level.
    static func apply(_ specks: [Speck], to image: DecodedImage) -> DecodedImage {
        let channels = image.samples.count / (image.width * image.height)
        var period = (1, 1)
        if case let .mosaic(pattern) = image.layout {
            period = (pattern.width, pattern.height)
        }
        var samples = image.samples
        for speck in specks {
            let reach = Int(ceil(speck.width * speck.aspect * 4))
            let cx = speck.center.x * Double(image.width), cy = speck.center.y * Double(image.height)
            let (cosine, sine) = (cos(speck.angle), sin(speck.angle))
            for y in max(Int(cy) - reach, 0) ..< min(Int(cy) + reach, image.height) {
                for x in max(Int(cx) - reach, 0) ..< min(Int(cx) + reach, image.width) {
                    let (dx, dy) = (Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)
                    let u = (dx * cosine + dy * sine) / (speck.width * speck.aspect)
                    let v = (-dx * sine + dy * cosine) / speck.width
                    let shade = 1 - speck.depth * exp(-(u * u + v * v) / 2)
                    for channel in 0 ..< channels {
                        let entry = channels == 1 ? (y % period.1) * period.0 + x % period.0 : channel
                        let black = image.blackLevels.isEmpty
                            ? 0 : Double(image.blackLevels[entry % image.blackLevels.count])
                        let index = (y * image.width + x) * channels + channel
                        let value = black + (Double(samples[index]) - black) * shade
                        samples[index] = UInt16(min(max(value.rounded(), 0), 65535))
                    }
                }
            }
        }
        var copy = DecodedImage(
            width: image.width, height: image.height, layout: image.layout, samples: samples,
            blackLevels: image.blackLevels, whiteLevel: image.whiteLevel, asShotMultipliers: image.asShotMultipliers,
            cameraToSRGB: image.cameraToSRGB, xyzToCamera: image.xyzToCamera, orientation: image.orientation,
            baselineExposure: image.baselineExposure, info: image.info,
        )
        copy.noiseProfile = image.noiseProfile
        copy.gainMaps = image.gainMaps
        copy.dngColor = image.dngColor
        copy.dngProfile = image.dngProfile
        return copy
    }

    /// The raw at half size or a third, as linear RGB cut to `width` x `height` from its middle:
    /// each block of the colour pattern that holds every colour (2 x 2 Bayer, 3 x 3 X-Trans)
    /// becomes a pixel, its samples of each colour averaged above their black levels. Frames of
    /// several cameras then pass for frames of one sensor, covering most of each scene.
    static func binned(_ image: DecodedImage, width: Int, height: Int) -> DecodedImage? {
        var block = 2
        var colors: [UInt8] = []
        var period = (1, 1)
        switch image.layout {
        case let .mosaic(pattern):
            block = pattern.width == 6 ? 3 : 2
            colors = pattern.colors
            period = (pattern.width, pattern.height)
        case .linearRGB:
            break
        default:
            return nil
        }
        let ox = (image.width / block - width) / 2, oy = (image.height / block - height) / 2
        guard ox >= 0, oy >= 0 else { return nil }
        let channels = colors.isEmpty ? 3 : 1
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for row in 0 ..< height {
            for column in 0 ..< width {
                var sums = SIMD3<Double>.zero, counts = SIMD3<Double>.zero
                for y in (row + oy) * block ..< (row + oy + 1) * block {
                    for x in (column + ox) * block ..< (column + ox + 1) * block {
                        for channel in 0 ..< channels {
                            let entry = channels == 1 ? (y % period.1) * period.0 + x % period.0 : channel
                            let color = channels == 1 ? Int(colors[entry]) : channel
                            let black = image.blackLevels.isEmpty
                                ? 0 : Double(image.blackLevels[entry % image.blackLevels.count])
                            sums[color] += Double(image.samples[(y * image.width + x) * channels + channel]) - black
                            counts[color] += 1
                        }
                    }
                }
                for color in 0 ..< 3 {
                    let mean = sums[color] / max(counts[color], 1)
                    samples[(row * width + column) * 3 + color] = UInt16(min(max(mean.rounded(), 0), 65535))
                }
            }
        }
        var info = image.info
        info.make = "Synthetic"
        info.model = "Shoot"
        info.pixelSize = PixelSize(width: width, height: height)
        var copy = DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples, blackLevels: [0, 0, 0],
            whiteLevel: image.whiteLevel - (image.blackLevels.min() ?? 0),
            asShotMultipliers: image.asShotMultipliers, cameraToSRGB: image.cameraToSRGB,
            xyzToCamera: image.xyzToCamera, orientation: 0, baselineExposure: image.baselineExposure, info: info,
        )
        copy.dngColor = image.dngColor
        copy.dngProfile = image.dngProfile
        return copy
    }

    /// Whether a person would see the speck: it darkens the photo at least five times as much as
    /// the photo varies around it at the speck's own size, as sky, walls and water allow and
    /// foliage or stone don't. The variation is the robust spread of the means of green in boxes
    /// about the speck's width, on a ring around it.
    static func isVisible(_ speck: Speck, in image: DecodedImage) -> Bool {
        let channels = image.samples.count / (image.width * image.height)
        var colors: [UInt8] = [1]
        var period = (1, 1)
        if case let .mosaic(pattern) = image.layout {
            colors = pattern.colors
            period = (pattern.width, pattern.height)
        }
        let box = max(Int(speck.width.rounded()), 2)
        let cx = speck.center.x * Double(image.width), cy = speck.center.y * Double(image.height)
        let inner = speck.width * speck.aspect * 2.5, outer = speck.width * speck.aspect * 5 + Double(box * 3)
        var means: [Double] = []
        for top in stride(from: Int(cy - outer), to: Int(cy + outer), by: box) {
            for left in stride(from: Int(cx - outer), to: Int(cx + outer), by: box) {
                let distance = hypot(Double(left) + Double(box) / 2 - cx, Double(top) + Double(box) / 2 - cy)
                guard distance >= inner, distance <= outer, left >= 0, top >= 0,
                      left + box <= image.width, top + box <= image.height
                else { continue }
                var sum = 0.0, count = 0.0
                for y in top ..< top + box {
                    for x in left ..< left + box {
                        let entry = channels == 1 ? (y % period.1) * period.0 + x % period.0 : 1
                        guard channels != 1 || colors[entry % colors.count] == 1 else { continue }
                        let black = image.blackLevels.isEmpty
                            ? 0 : Double(image.blackLevels[entry % image.blackLevels.count])
                        let index = (y * image.width + x) * channels + (channels == 3 ? 1 : 0)
                        sum += max(Double(image.samples[index]) - black, 1)
                        count += 1
                    }
                }
                if count > 0 {
                    means.append(log(sum / count))
                }
            }
        }
        guard means.count >= 12 else { return false }
        let median = means.sorted()[means.count / 2]
        let spread = 1.4826 * means.map { abs($0 - median) }.sorted()[means.count / 2]
        return -log(1 - speck.depth) >= 5 * spread
    }

    // MARK: - Measuring

    struct Score {
        /// Round specks.
        var visible = 0
        var found = 0
        var fibres = 0
        var fibresFound = 0
        var falseFinds = 0
        var frames = 0

        mutating func add(_ other: Score) {
            visible += other.visible
            found += other.found
            fibres += other.fibres
            fibresFound += other.fibresFound
            falseFinds += other.falseFinds
            frames += other.frames
        }

        var recall: Double {
            visible == 0 ? 1 : Double(found) / Double(visible)
        }

        var falsePerFrame: Double {
            frames == 0 ? 0 : Double(falseFinds) / Double(frames)
        }
    }

    /// Where each speck lies in the photo as shown, in its pixels, and how near a detection must
    /// be to count as finding it: a few of its widths, at least 8 pixels.
    static func targets(_ specks: [Speck], in image: DecodedImage) -> [(center: SIMD2<Double>, reach: Double)] {
        let shown = image.orientedSize
        return specks.map { speck in
            let point = orientedCoordinate(speck.center, orientation: image.orientation)
            return (
                SIMD2(point.x * Double(shown.width), point.y * Double(shown.height)),
                max(speck.width * speck.aspect * 2.5, 8),
            )
        }
    }

    static func pixels(_ spot: DetectedSpot, in image: DecodedImage) -> SIMD2<Double> {
        let shown = image.orientedSize
        return SIMD2(spot.center.x * Double(shown.width), spot.center.y * Double(shown.height))
    }

    /// Whether a detection is one of the specks the photo already had.
    static func isKnown(_ spot: DetectedSpot, in image: DecodedImage) -> Bool {
        let shown = image.orientedSize
        return (DustSamples.known[image.info.url.lastPathComponent] ?? []).contains { point in
            let place = SIMD2(point.x * Double(shown.width), point.y * Double(shown.height))
            return simd_distance(pixels(spot, in: image), place) < 20
        }
    }

    /// Visible specks found, and detections near no speck.
    static func score(_ found: [DetectedSpot], specks: [Speck], image: DecodedImage) -> Score {
        let targets = targets(specks, in: image)
        let near = { (spot: DetectedSpot, target: (center: SIMD2<Double>, reach: Double)) in
            simd_distance(pixels(spot, in: image), target.center) < target.reach
        }
        var score = Score(frames: 1)
        for (speck, target) in zip(specks, targets) where isVisible(speck, in: image) {
            let hit = found.contains { near($0, target) }
            if speck.aspect > 1 {
                score.fibres += 1
                score.fibresFound += hit ? 1 : 0
            } else {
                score.visible += 1
                score.found += hit ? 1 : 0
            }
        }
        score.falseFinds = found.count { spot in !targets.contains { near(spot, $0) } && !isKnown(spot, in: image) }
        return score
    }

    /// Of the specks found in enough frames to tell them for dust, those placed in nearly every
    /// frame (`visible` counting the first, `found` the second), and placed spots near no speck.
    static func scoreShoot(
        _ shoot: [URL: [DetectedSpot]], frames: [ShootDust.Frame], images: [DecodedImage], specks: [Speck],
    ) -> Score {
        let needed = max(ShootDust.minimumFrames, Int(ceil(ShootDust.minimumShare * Double(frames.count))))
        var score = Score(frames: frames.count)
        for speck in specks {
            let detected = zip(frames, images).count { frame, image in
                let target = targets([speck], in: image)[0]
                return frame.specks.contains { simd_distance(pixels($0.spot, in: image), target.center) < target.reach }
            }
            guard detected >= needed else { continue }
            score.visible += 1
            let placed = zip(frames, images).count { frame, image in
                let target = targets([speck], in: image)[0]
                return (shoot[frame.url] ?? []).contains {
                    simd_distance(pixels($0, in: image), target.center) < target.reach
                }
            }
            if Double(placed) >= 0.9 * Double(frames.count) {
                score.found += 1
            }
        }
        for (frame, image) in zip(frames, images) {
            let targets = targets(specks, in: image)
            score.falseFinds += (shoot[frame.url] ?? []).count { spot in
                !targets.contains { simd_distance(pixels(spot, in: image), $0.center) < $0.reach }
                    && !isKnown(spot, in: image)
            }
        }
        return score
    }

    func session(_ image: DecodedImage) throws -> ImageSession {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        return try SessionBuilder(device: device, queue: queue, kernels: KernelLibrary(device: device)).build(image)
    }

    // MARK: - Tests

    @Test func `dust added to real photos is found where it shows, and little else`() throws {
        let engine = try RedlampEngine()
        var total = Score()
        for (index, url) in DustSamples.scenes.enumerated() {
            let clean = try ImageDecoder.decode(url)
            let specks = Self.pattern(seed: UInt64(index + 1), count: 20)
            let found = try engine.findDust(
                recipe: EditRecipe(), sensitivity: 50, session: session(Self.apply(specks, to: clean)),
            )
            total.add(Self.score(found, specks: specks, image: clean))
        }
        // Fibres aren't round, so few pass for dust: they're counted apart, without a bar.
        #expect(total.recall >= 0.7, "found \(total.found) of \(total.visible) round specks")
        #expect(total.falsePerFrame <= 0.5, "false finds a frame: \(total.falsePerFrame)")
    }

    /// Each scene binned and cut to one size, as frames of one shoot from one sensor, the dust
    /// in the same place in each: dust found in a few frames reaches all of them, textured ones
    /// too. (How often a frame finds what it shows, the photos test measures.)
    @Test func `across a varied shoot, dust found in a few frames reaches every frame`() throws {
        let engine = try RedlampEngine()
        let specks = Self.pattern(seed: 77, count: 40, scale: 0.5)
        var frames: [ShootDust.Frame] = []
        var images: [DecodedImage] = []
        for url in DustSamples.scenes {
            guard let frame = try Self.binned(ImageDecoder.decode(url), width: 2000, height: 1400) else { continue }
            let session = try session(Self.apply(specks, to: frame))
            let found = try engine.findSpecks(recipe: EditRecipe(), sensitivity: 65, session: session)
            frames.append(ShootDust.Frame(url: url, recipe: EditRecipe(), session: session, specks: found))
            images.append(frame)
        }
        try #require(frames.count >= 5)
        let score = Self.scoreShoot(ShootDust.consistent(frames), frames: frames, images: images, specks: specks)
        #expect(score.visible >= 3, "only \(score.visible) specks found in enough frames")
        #expect(score.recall >= 0.9, "\(score.found) of \(score.visible) reached every frame")
        #expect(score.falsePerFrame <= 0.25, "false finds a frame: \(score.falsePerFrame)")
    }

    /// The same scene six times (a tripod): repetition proves nothing about the scene's own
    /// specks, so they mustn't be taken for dust, while dust on plain parts of it still reaches
    /// every frame.
    @Test(.enabled(if: DustSamples.series.count >= 4))
    func `on a tripod, dust reaches every frame and the scene's specks don't`() throws {
        let engine = try RedlampEngine()
        let specks = Self.pattern(seed: 5)
        var frames: [ShootDust.Frame] = []
        var images: [DecodedImage] = []
        let decoded = try DustSamples.series.map { try ($0, ImageDecoder.decode($0)) }
        let widths = Dictionary(grouping: decoded.map(\.1.width)) { $0 }
        let common = widths.max { $0.value.count < $1.value.count }?.key
        // The frames in smaller crop modes show another part of the sensor.
        for (url, clean) in decoded where clean.width == common {
            let session = try session(Self.apply(specks, to: clean))
            let found = try engine.findSpecks(recipe: EditRecipe(), sensitivity: 65, session: session)
            frames.append(ShootDust.Frame(url: url, recipe: EditRecipe(), session: session, specks: found))
            images.append(clean)
        }
        let score = Self.scoreShoot(ShootDust.consistent(frames), frames: frames, images: images, specks: specks)
        #expect(score.visible >= 1, "no speck found in enough frames")
        #expect(score.recall >= 0.9, "\(score.found) of \(score.visible) reached every frame")
        #expect(score.falsePerFrame <= 0.25, "false finds a frame: \(score.falsePerFrame)")
    }
}
