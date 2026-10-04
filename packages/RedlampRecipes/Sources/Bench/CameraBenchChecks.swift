import Foundation
import RedlampEngineAPI

/// The camera bench's checks (CAM-14) and their thresholds, all in one place so the
/// documentation (`docs/camera-bench.md`) and the aggregator can follow them. A check's
/// version changes whenever its measurements or thresholds do.
public enum CameraBenchChecks {
    enum Threshold {
        /// The masked margins' offset from the stated black, in their own noise sigmas (and at
        /// least this many raw units).
        static let marginSigmas = (warn: 3.0, fail: 5.0)
        static let marginUnits = (warn: 2.0, fail: 4.0)
        /// And, to fail, more than this share of the range: what shows in the shadows.
        static let marginRange = 0.01
        /// Margins below this share of the stated black are padding.
        static let paddingShare = 0.25
        /// How far below the stated black the 0.1th percentile may sit, as a share of the range.
        static let belowBlack = (warn: 0.01, fail: 0.02)
        /// Multipliers further than this from green's, either way, are implausible.
        static let multiplierRange = 0.2 ... 8.0
        /// Edges of the comparison.
        static let turnGain = 0.15
        static let correlation = (warn: 0.5, fail: 0.25)
        static let scale = (warn: 0.03, fail: 0.07)
        static let offset = (warn: 0.02, fail: 0.05)
        static let aspect = 0.02
        /// Redlamp's default is up to 1.7 stops darker than some cameras' JPEGs (the Canon 5D
        /// Mark IV's), by design; a wrong white or black level moves it further.
        static let exposureStops = (warn: 2.0, fail: 3.0)
        static let cast = (warn: 4.0, fail: 8.0)
        static let highlightChroma = (warn: 4.0, fail: 8.0)
        static let colourDifference = 15.0
    }

    // MARK: - Opening

    public static func opened() -> BenchCheck {
        BenchCheck(id: "decode.opens", version: 1, verdict: .pass, summary: "Redlamp opened the file.")
    }

    public static func refused(_ identity: RawFileIdentity, error: any Error) -> BenchCheck {
        let reason = identity.refusal ?? String(describing: error)
        let known = knownLimitation(identity, reason: reason)
        return BenchCheck(
            id: "decode.opens", version: 1, verdict: .fail,
            summary: known?.summary ?? "Redlamp couldn't open the file: \(reason).", tracker: known?.tracker,
        )
    }

    /// Refusals a tracker row already covers.
    static func knownLimitation(_ identity: RawFileIdentity, reason: String) -> (tracker: String, summary: String)? {
        let make = (identity.normalizedMake ?? identity.make ?? "").lowercased()
        let model = (identity.normalizedModel ?? identity.model ?? "").uppercased().replacingOccurrences(
            of: " ",
            with: "",
        )
        if make.contains("nikon"), ["Z8", "Z9", "Z6_3", "Z6III", "ZF"].contains(where: { model.hasSuffix($0) }) {
            return ("CAM-12", "Nikon's High Efficiency NEFs (HE and HE*) don't open yet: LibRaw 0.22 can't read them.")
        }
        if identity.format == "DNG", reason.localizedCaseInsensitiveContains("JPEG XL") {
            return ("CAM-10", "JPEG XL mosaic DNGs don't open yet.")
        }
        if make.contains("sony"), ["ILCE-7M5", "ILCE-1M2"].contains(where: { model.hasSuffix($0) }) {
            return ("CAM-13", "This body needs a newer LibRaw than 0.22.2.")
        }
        return nil
    }

    // MARK: - The decode

    /// Checks on what the decoder measured.
    public static func decode(_ measured: DecodeMeasurements, identity: RawFileIdentity) -> [BenchCheck] {
        [black(measured), white(measured), colour(measured, identity: identity), edges(measured)]
    }

    static func black(_ m: DecodeMeasurements) -> BenchCheck {
        let range = max(m.white - m.black, 1)
        var numbers = ["black": m.black, "white": m.white]
        var verdict = BenchVerdict.pass
        var findings: [String] = []
        // Margins far below the stated black are padding, not masked photosites (the Fujifilm F770EXR's).
        if let optical = m.opticalBlack, let noise = m.opticalBlackNoise, optical >= Threshold.paddingShare * m.black {
            numbers["opticalBlack"] = optical
            numbers["opticalBlackNoise"] = noise
            let offset = abs(optical - m.black)
            // A camera can offset its margins from the image area by a little (Pentax's, CHDK's), so only an
            // offset that would show in the shadows fails.
            if offset > max(Threshold.marginUnits.fail, Threshold.marginSigmas.fail * noise),
               offset > Threshold.marginRange * range {
                verdict = .fail
            } else if offset > max(Threshold.marginUnits.warn, Threshold.marginSigmas.warn * noise) {
                verdict = max(verdict, .warn)
            }
            if offset > max(Threshold.marginUnits.warn, Threshold.marginSigmas.warn * noise) {
                findings.append(String(format: "the masked margins sit at %.1f, not the stated %.1f", optical, m.black))
            }
        }
        numbers["zeroShare"] = m.zeroShare
        if let dark = m.darkPercentile {
            numbers["darkPercentile"] = dark
            let below = (m.black - dark) / range
            if below > Threshold.belowBlack.fail {
                verdict = .fail
            } else if below > Threshold.belowBlack.warn {
                verdict = max(verdict, .warn)
            }
            if below > Threshold.belowBlack.warn {
                findings.append(String(format: "many photosites sit %.1f%% of the range below it", below * 100))
            }
        }
        let summary = findings.isEmpty
            ? String(format: "The black level (%.1f) agrees with the sensor.", m.black)
            : "The black level may be wrong: " + findings.joined(separator: "; ") + "."
        return BenchCheck(id: "decode.black", version: 3, verdict: verdict, measurements: numbers, summary: summary)
    }

    static func white(_ m: DecodeMeasurements) -> BenchCheck {
        var numbers = ["white": m.white, "nominalWhite": m.nominalWhite, "black": m.black]
        numbers["clippedShare"] = m.clippedShare
        guard m.white > m.black * 1.1 + 16 else {
            return BenchCheck(
                id: "decode.white", version: 1, verdict: .fail, measurements: numbers,
                summary: String(format: "The white level (%.0f) is barely above black (%.0f).", m.white, m.black),
            )
        }
        let clipped = (m.clippedShare ?? 0) >= 0.001
        let summary = m.white == m.nominalWhite
            ? String(format: "The white level is %.0f%@.", m.white, clipped ? ", where the highlights clip" : "")
            : String(
                format: "Photosites clip at %.0f (LibRaw states %.0f), which Redlamp uses.",
                m.white,
                m.nominalWhite,
            )
        return BenchCheck(id: "decode.white", version: 1, verdict: .pass, measurements: numbers, summary: summary)
    }

    static func colour(_ m: DecodeMeasurements, identity: RawFileIdentity) -> BenchCheck {
        guard m.colorMatrix != nil else {
            return BenchCheck(
                id: "decode.colour", version: 1, verdict: .fail,
                summary: "The camera has no colour matrix, so its colours can't be right.",
            )
        }
        guard let multipliers = identity.asShotMultipliers else {
            return BenchCheck(
                id: "decode.colour", version: 1, verdict: .warn,
                summary: "The file states no white balance; Redlamp uses a neutral one.",
            )
        }
        let numbers = ["red": multipliers[0], "blue": multipliers[2]]
        let plausible = Threshold.multiplierRange.contains(multipliers[0])
            && Threshold.multiplierRange.contains(multipliers[2])
        return BenchCheck(
            id: "decode.colour", version: 1, verdict: plausible ? .pass : .warn, measurements: numbers,
            summary: plausible
                ? "The colour matrix and the camera's white balance are there."
                : String(
                    format: "The camera's white balance looks implausible (red %.2f, blue %.2f).",
                    multipliers[0],
                    multipliers[2],
                ),
        )
    }

    /// Strips along the edges at the black level. With the camera's JPEG, a strip the camera's
    /// rendering is dark along too (a fisheye's or a 360° camera's image circle) isn't a fault.
    public static func edges(
        _ m: DecodeMeasurements, identity: RawFileIdentity? = nil, camera: PixelImage? = nil,
    ) -> BenchCheck {
        guard let edges = m.darkEdges else {
            return BenchCheck(
                id: "decode.edges",
                version: 2,
                verdict: .skipped,
                summary: "Not measured for this sensor.",
            )
        }
        let numbers = [
            "top": Double(edges.top), "bottom": Double(edges.bottom),
            "left": Double(edges.left), "right": Double(edges.right),
        ]
        guard edges.widest > 0 else {
            return BenchCheck(
                id: "decode.edges", version: 2, verdict: .pass, measurements: numbers,
                summary: "No empty strips along the edges.",
            )
        }
        if let identity, let camera, cameraIsDark(along: edges, identity: identity, in: camera) {
            return BenchCheck(
                id: "decode.edges", version: 2, verdict: .pass, measurements: numbers,
                summary: "Dark along the edges, as the camera's JPEG is: the lens's image circle, not the decode.",
            )
        }
        let sides = [("top", edges.top), ("bottom", edges.bottom), ("left", edges.left), ("right", edges.right)]
            .filter { $0.1 > 0 }.map { "\($0.1) along the \($0.0)" }
        return BenchCheck(
            id: "decode.edges", version: 2, verdict: .fail, measurements: numbers,
            summary: "Lines at the black level: " + sides.joined(separator: ", ") + ".",
        )
    }

    /// Whether the camera's JPEG is dark along every side the decode has a strip on. Strips are
    /// counted on the sensor; the JPEG is upright, so sides follow the orientation.
    static func cameraIsDark(along edges: DarkEdges, identity: RawFileIdentity, in camera: PixelImage) -> Bool {
        let size = identity.imageSize
        guard size.width > 0, size.height > 0 else { return false }
        // Sensor side → (upright side, its share of the sensor's height or width).
        let strips: [(Int, Double)] = [
            (edges.top, Double(edges.top) / Double(size.height)), (
                edges.right,
                Double(edges.right) / Double(size.width),
            ),
            (edges.bottom, Double(edges.bottom) / Double(size.height)), (
                edges.left,
                Double(edges.left) / Double(size.width),
            ),
        ]
        let turns = switch identity.orientation {
        case 6: 1
        case 3: 2
        case 5: 3
        default: 0
        }
        for (side, strip) in strips.enumerated() where strip.0 > 0 {
            // 0 top, 1 right, 2 bottom, 3 left, turned clockwise with the photo.
            let upright = (side + turns) % 4
            let vertical = upright == 0 || upright == 2
            let extent = vertical ? camera.height : camera.width
            let band = max(1, Int((strip.1 * Double(extent)).rounded()))
            var sum: Float = 0, count: Float = 0
            for y in 0 ..< camera.height {
                for x in 0 ..< camera.width {
                    let inside = switch upright {
                    case 0: y < band
                    case 1: x >= camera.width - band
                    case 2: y >= camera.height - band
                    default: x < band
                    }
                    if inside {
                        sum += PhotoPairAnalysis.luma(ColorMath.srgbDecode(camera[x, y]))
                        count += 1
                    }
                }
            }
            if count == 0 || sum / count > 0.01 {
                return false
            }
        }
        return true
    }

    // MARK: - Against the camera's JPEG

    public static func rendered(_ ok: Bool) -> BenchCheck {
        BenchCheck(
            id: "render.default", version: 1, verdict: ok ? .pass : .fail,
            summary: ok ? "The default edit rendered." : "Redlamp couldn't render the default edit.",
        )
    }

    /// Checks comparing the default rendering with the camera's JPEG; skipped without one.
    public static func preview(_ comparison: CameraJPEGComparison?, hasPreview: Bool) -> [BenchCheck] {
        guard let c = comparison else {
            let why = hasPreview ? "The comparison couldn't be made." : "The file embeds no JPEG to compare with."
            return [
                "preview.orientation",
                "preview.framing",
                "preview.structure",
                "preview.exposure",
                "preview.cast",
                "preview.highlights",
                "preview.colour",
            ].map {
                BenchCheck(id: $0, version: 1, verdict: .skipped, summary: why)
            }
        }
        return [orientation(c), framing(c), structure(c), exposure(c), cast(c), highlights(c), colourDifference(c)]
    }

    static func orientation(_ c: CameraJPEGComparison) -> BenchCheck {
        let numbers = ["quarterTurns": Double(c.quarterTurns), "turnGain": c.turnGain]
        let turned = c.quarterTurns != 0 && c.turnGain > Threshold.turnGain
        return BenchCheck(
            id: "preview.orientation", version: 1, verdict: turned ? .fail : .pass, measurements: numbers,
            summary: turned
                ? "Redlamp's is turned \(c.quarterTurns * 90)° from the camera's."
                : "The same way up as the camera's.",
        )
    }

    static func framing(_ c: CameraJPEGComparison) -> BenchCheck {
        let numbers = [
            "ourAspect": c.ourAspect, "theirAspect": c.theirAspect, "scale": c.scale,
            "offsetX": c.offsetX, "offsetY": c.offsetY,
        ]
        let scale = abs(c.scale - 1), offset = max(abs(c.offsetX), abs(c.offsetY))
        let aspect = abs(c.ourAspect / c.theirAspect - 1)
        let verdict: BenchVerdict = scale > Threshold.scale.fail || offset > Threshold.offset.fail ? .fail
            : scale > Threshold.scale.warn || offset > Threshold.offset.warn || aspect > Threshold
            .aspect ? .warn : .pass
        var summary = String(format: "Framed like the camera's (scale %.3f, offset %.3f).", c.scale, offset)
        if verdict != .pass {
            summary = String(
                format: "Framed differently from the camera's: scale %.3f, offset %.3f, aspect %.3f against %.3f.",
                c.scale, offset, c.ourAspect, c.theirAspect,
            )
            if scale > Threshold.scale.warn, offset <= Threshold.offset.warn {
                summary += " Often the camera's own lens correction, which Redlamp doesn't read for every maker."
            }
        }
        return BenchCheck(id: "preview.framing", version: 1, verdict: verdict, measurements: numbers, summary: summary)
    }

    static func structure(_ c: CameraJPEGComparison) -> BenchCheck {
        let verdict: BenchVerdict = c.correlation < Threshold.correlation.fail ? .fail
            : c.correlation < Threshold.correlation.warn ? .warn : .pass
        return BenchCheck(
            id: "preview.structure", version: 1, verdict: verdict, measurements: ["correlation": c.correlation],
            summary: verdict == .pass
                ? String(format: "The same detail as the camera's (correlation %.2f).", c.correlation)
                : String(format: "The detail doesn't match the camera's well (correlation %.2f).", c.correlation),
        )
    }

    static func exposure(_ c: CameraJPEGComparison) -> BenchCheck {
        guard let stops = c.exposure else {
            return BenchCheck(
                id: "preview.exposure",
                version: 1,
                verdict: .skipped,
                summary: "Too few midtones to compare.",
            )
        }
        let verdict: BenchVerdict = abs(stops) > Threshold.exposureStops.fail ? .fail
            : abs(stops) > Threshold.exposureStops.warn ? .warn : .pass
        return BenchCheck(
            id: "preview.exposure", version: 1, verdict: verdict, measurements: ["stops": stops],
            summary: String(
                format: "%@ than the camera's by %.2f stops in the midtones.",
                stops >= 0 ? "Brighter" : "Darker",
                abs(stops),
            ),
        )
    }

    static func cast(_ c: CameraJPEGComparison) -> BenchCheck {
        guard let cast = c.cast else {
            let why = c.monochrome ? "The camera's JPEG is black and white." : "Too few neutral areas to compare."
            return BenchCheck(
                id: "preview.cast", version: 1, verdict: .skipped,
                measurements: ["neutralSamples": Double(c.neutralSamples)], summary: why,
            )
        }
        let verdict: BenchVerdict = cast > Threshold.cast.fail ? .fail : cast > Threshold.cast.warn ? .warn : .pass
        return BenchCheck(
            id: "preview.cast", version: 1, verdict: verdict,
            measurements: ["cast": cast, "neutralSamples": Double(c.neutralSamples)],
            summary: verdict == .pass
                ? String(format: "Neutral where the camera's is (%.1f).", cast)
                : String(format: "A colour cast where the camera's is neutral (%.1f).", cast),
        )
    }

    static func highlights(_ c: CameraJPEGComparison) -> BenchCheck {
        guard let chroma = c.highlightChroma else {
            return BenchCheck(
                id: "preview.highlights", version: 1, verdict: .skipped,
                measurements: ["highlightSamples": Double(c.highlightSamples)],
                summary: "No white highlights to compare.",
            )
        }
        let verdict: BenchVerdict = chroma > Threshold.highlightChroma.fail ? .fail
            : chroma > Threshold.highlightChroma.warn ? .warn : .pass
        return BenchCheck(
            id: "preview.highlights", version: 1, verdict: verdict,
            measurements: ["chroma": chroma, "highlightSamples": Double(c.highlightSamples)],
            summary: verdict == .pass
                ? "White where the camera's highlights are white."
                : String(format: "Tinted where the camera's highlights are white (%.1f).", chroma),
        )
    }

    static func colourDifference(_ c: CameraJPEGComparison) -> BenchCheck {
        guard let difference = c.colourDifference else {
            return BenchCheck(id: "preview.colour", version: 1, verdict: .skipped, summary: "Colours not compared.")
        }
        return BenchCheck(
            id: "preview.colour", version: 1, verdict: difference > Threshold.colourDifference ? .warn : .pass,
            measurements: ["difference": difference, "samples": Double(c.colourSamples)],
            summary: String(
                format: "Colours differ from the camera's by %.1f on average, its picture style included.",
                difference,
            ),
        )
    }
}
