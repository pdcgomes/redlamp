import Foundation
import RedlampEngineAPI
import simd
import Testing
@testable import RedlampServices

/// Adobe lens profiles (LNS-04): the reader, and the Adobe Camera Model tabulated into a
/// `LensCorrection`, against values computed from the published equations.
struct LCPProfileTests {
    static let size = PixelSize(width: 6000, height: 4000)

    static func profile(_ specs: [SyntheticLCP.Spec], form: SyntheticLCP.Form = .elements) throws -> LCPProfile {
        try LCPProfile(data: SyntheticLCP.file(specs, form: form))
    }

    static func correction(
        _ specs: [SyntheticLCP.Spec],
        focalLength: Double? = 24,
        aperture: Double? = 4,
        size: PixelSize = size,
        orientation: Int = 0,
    ) throws -> LensCorrection? {
        try LCPProfile.correction(
            profile(specs).subProfiles, focalLength: focalLength, aperture: aperture, size: size,
            orientation: orientation,
        )
    }

    /// The largest difference between two corrections' tables and centres.
    static func difference(_ a: LensCorrection, _ b: LensCorrection) -> Double {
        guard a.radii == b.radii, a.distortion.count == b.distortion.count, a.vignetting.count == b.vignetting.count
        else { return .infinity }
        let scales = zip(a.distortion, b.distortion).map { simd_abs($0 - $1).max() }
        let gains = zip(a.vignetting, b.vignetting).map { abs($0 - $1) }
        return (scales + gains + [simd_abs(a.center - b.center).max()]).max() ?? 0
    }

    @Test func `reads the element and attribute forms of RDF alike`() throws {
        let elements = try Self.profile([SyntheticLCP.Spec()])
        let attributes = try Self.profile([SyntheticLCP.Spec()], form: .attributes)
        #expect(elements.subProfiles == attributes.subProfiles && elements.skipped.isEmpty)
        let lens = try #require(attributes.subProfiles.first)
        #expect(lens.make == "NIKON CORPORATION" && lens.model == "NIKON Z 6" && lens.cameraPrettyName == "Nikon Z 6")
        #expect(lens.lens == "NIKKOR Z 24-70mm f/4 S" && lens.lensPrettyName == "Nikon NIKKOR Z 24-70mm f/4 S")
        #expect(lens.name == "Synthetic (Nikon NIKKOR Z 24-70mm f/4 S)")
        #expect(lens.focalLength == 24 && lens.apertureValue == 4 && lens.focusDistance == 3)
        #expect(lens.imageSize == SIMD2(6000, 4000) && lens.isRaw && lens.sensorFormatFactor == nil)
        let distortion = try #require(lens.distortion)
        #expect(distortion.focalLength == SIMD2(0.68, 0.68) && distortion.centerX == 0.51 && distortion.centerY == 0.32)
        #expect(distortion.radial == SIMD3(-0.12, 0.05, -0.01) && distortion.tangential == SIMD2(0.0003, -0.0002))
        let chromatic = try #require(lens.chromatic)
        #expect(chromatic.green.radial == SIMD3(-0.121, 0.051, -0.011) && chromatic.green.scale == 1)
        #expect(chromatic.red.scale == 1.0004 && chromatic.red.radial == SIMD3(0.0008, -0.0004, 0))
        #expect(chromatic.blue.scale == 0.9997 && chromatic.blue.radial == SIMD3(-0.0006, 0.0002, 0))
        #expect(lens.vignette?.radial == SIMD3(-0.6, 0.15, -0.02))
    }

    @Test func `reads the camera profile namespace whatever its prefix`() throws {
        let renamed = try LCPProfile(data: SyntheticLCP.file([SyntheticLCP.Spec()], form: .attributes, prefix: "cp"))
        #expect(try renamed.subProfiles == Self.profile([SyntheticLCP.Spec()]).subProfiles)
    }

    @Test func `a file that isn't a lens profile can't be read`() {
        #expect(throws: LCPProfile.ReadError.self) { try LCPProfile(data: Data("<x:xmpmeta".utf8)) }
        #expect(throws: LCPProfile.ReadError.self) {
            try LCPProfile(data: Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#.utf8))
        }
    }

    @Test func `a fisheye sub-profile is left out, with the reason`() throws {
        var fisheye = SyntheticLCP.Spec()
        fisheye.fisheye = true
        fisheye.focalLength = 15
        let profile = try Self.profile([fisheye, SyntheticLCP.Spec()])
        #expect(profile.subProfiles.map(\.focalLength) == [24])
        #expect(profile.skipped == [
            "Synthetic (Nikon NIKKOR Z 24-70mm f/4 S) at 15 mm: fisheye profiles aren't supported yet",
        ])
    }

    @Test func `the tables follow the published equations`() throws {
        let lens = try #require(try Self.correction([SyntheticLCP.Spec()]))
        #expect(lens.source == .dng && lens.radii == LCPProfile.radii)
        // Every model's principal point is (3060, 1920) of 6000 × 4000, so its farthest corner is
        // 3700 pixels away.
        #expect(simd_distance(lens.center, SIMD2(0.51, 0.48)) < 1e-12)
        // Red's, green's and blue's recorded scale and the vignetting gain at radii of 0.2625,
        // 0.525, 0.7875 and 1.05 corners, from the two-dimensional equations at points along a
        // diagonal, tangential terms left out (computed separately, in Python). At the centre, red
        // and blue keep their scale factors α₀ and β₀.
        let expected: [(index: Int, scales: SIMD3<Double>, gain: Double)] = [
            (0, SIMD3(1.0004, 1, 0.9997), 1),
            (8, SIMD3(0.993745414122, 0.993304886671, 0.992974203325), 1.034685817486),
            (16, SIMD3(0.975604847464, 0.975064766801, 0.974655257739), 1.147486662096),
            (24, SIMD3(0.950744178387, 0.950094657366, 0.949587526687), 1.369198416034),
            (32, SIMD3(0.924737942424, 0.924017442074, 0.923421891226), 1.771827032281),
        ]
        for (index, scales, gain) in expected {
            #expect(simd_abs(lens.distortion[index] - scales).max() < 1e-11, "scales at \(lens.radii[index])")
            #expect(abs(lens.vignetting[index] - gain) < 1e-11, "gain at \(lens.radii[index])")
        }
        #expect(lens.correctsColorFringes)
    }

    @Test func `without colour models every channel follows the rectilinear model`() throws {
        var plain = SyntheticLCP.Spec()
        plain.colour = false
        let lens = try #require(try Self.correction([plain]))
        let expected = [(8, 0.993358525835), (16, 0.975251706466), (24, 0.950477220929), (32, 0.924847433147)]
        for (index, scale) in expected {
            #expect(simd_abs(lens.distortion[index] - SIMD3(repeating: scale)).max() < 1e-11, "\(lens.radii[index])")
        }
        #expect(!lens.correctsColorFringes)
    }

    @Test func `a model without a normalised focal length takes it from millimetres and the format factor`() throws {
        // 24 mm on a sensor 24 mm wide (1.5×) is the photo's width: 6000 pixels, 1 of the larger side.
        var derived = SyntheticLCP.Spec()
        derived.focal = nil
        derived.sensorFormatFactor = 1.5
        var normalised = SyntheticLCP.Spec()
        normalised.focal = 1
        let expected = try #require(try Self.correction([normalised]))
        #expect(try Self.difference(#require(try Self.correction([derived])), expected) < 1e-12)
        derived.sensorFormatFactor = nil
        #expect(try Self.correction([derived]) == nil)
    }

    @Test func `a turned photo's centre turns with it`() throws {
        let upright = try #require(try Self.correction([SyntheticLCP.Spec()]))
        let turned = try #require(try Self.correction([SyntheticLCP.Spec()], orientation: 6))
        #expect(simd_distance(turned.center, SIMD2(0.52, 0.51)) < 1e-12)
        #expect(turned.distortion == upright.distortion && turned.vignetting == upright.vignetting)
    }

    @Test func `focal lengths between the profile's interpolate, and beyond them the nearest holds`() throws {
        var wide = SyntheticLCP.Spec()
        wide.colour = false
        var long = wide
        long.focalLength = 70
        long.focal = 1.95
        long.distortion = SIMD3(0.02, -0.01, 0)
        long.vignette = SIMD3(-0.9, 0.3, 0)
        let atWide = try #require(try Self.correction([wide]))
        let atLong = try #require(try Self.correction([long], focalLength: 70))
        // 47 mm is halfway from 24 to 70.
        let between = try #require(try Self.correction([wide, long], focalLength: 47))
        for index in between.radii.indices {
            let scale = (atWide.distortion[index] + atLong.distortion[index]) / 2
            #expect(simd_abs(between.distortion[index] - scale).max() < 1e-12)
            #expect(abs(between.vignetting[index] - (atWide.vignetting[index] + atLong.vignetting[index]) / 2) < 1e-12)
        }
        #expect(try Self.correction([wide, long], focalLength: 16) == atWide)
        #expect(try Self.correction([wide, long], focalLength: 200) == atLong)
    }

    @Test func `vignetting interpolates between apertures in stops, the narrowest standing in for an unknown one`(
    ) throws {
        let open = SyntheticLCP.Spec()
        var stopped = open
        stopped.apertureValue = 6
        stopped.vignette = SIMD3(-0.25, 0.05, 0)
        let atF4 = try #require(try Self.correction([open]))
        let atF8 = try #require(try Self.correction([stopped], aperture: 8))
        // f/5.6 is 2 log₂ 5.6 = 4.97 in APEX: 0.485 of the way from f/4 (4) to f/8 (6).
        let t = (2 * log2(5.6) - 4) / 2
        let between = try #require(try Self.correction([open, stopped], aperture: 5.6))
        for index in between.radii.indices {
            let gain = atF4.vignetting[index] * (1 - t) + atF8.vignetting[index] * t
            #expect(abs(between.vignetting[index] - gain) < 1e-12)
            #expect(simd_abs(between.distortion[index] - atF4.distortion[index]).max() < 1e-12)
        }
        #expect(try Self.correction([open, stopped], aperture: nil) == atF8)
    }

    @Test func `of sub-profiles made at one setting, the one focused farthest applies`() throws {
        var near = SyntheticLCP.Spec()
        near.focusDistance = 0.5
        near.distortion = SIMD3(-0.2, 0, 0)
        near.colour = false
        var far = near
        far.focusDistance = 10
        far.distortion = SIMD3(-0.1, 0, 0)
        #expect(try Self.correction([near, far]) == Self.correction([far]))
    }

    @Test func `without the photo's focal length only a profile made at one focal length applies`() throws {
        var long = SyntheticLCP.Spec()
        long.focalLength = 70
        #expect(try Self.correction([SyntheticLCP.Spec(), long], focalLength: nil) == nil)
        #expect(try Self.correction([SyntheticLCP.Spec()], focalLength: nil) == Self.correction([SyntheticLCP.Spec()]))
    }

    @Test func `a photo of another shape than the reference photos gets no correction`() throws {
        #expect(try Self.correction([SyntheticLCP.Spec()], size: PixelSize(width: 6000, height: 3375)) == nil)
        #expect(try Self.correction([SyntheticLCP.Spec()], size: PixelSize(width: 6064, height: 4040)) != nil)
    }

    @Test func `a model that folds back on itself, or leaves no light, is dropped`() throws {
        var extreme = SyntheticLCP.Spec()
        extreme.colour = false
        extreme.distortion = SIMD3(-3, 0, 0)
        let folded = try #require(try Self.correction([extreme]))
        #expect(folded.distortion.isEmpty && !folded.vignetting.isEmpty)
        extreme.distortion = SIMD3(-0.12, 0.05, -0.01)
        extreme.vignette = SIMD3(-2, 0, 0)
        let dark = try #require(try Self.correction([extreme]))
        #expect(!dark.distortion.isEmpty && dark.vignetting.isEmpty)
    }
}

/// Synthetic lens profiles, written in either of RDF's forms; never Adobe's files.
enum SyntheticLCP {
    enum Form {
        case elements, attributes
    }

    /// A sub-profile: a Nikon Z 6 with its 24-70 mm zoom at 24 mm and f/4, measured on 6000 × 4000
    /// raws, every model's principal point at (0.51, 0.32) of the larger side and fx = fy = 0.68 of it.
    struct Spec {
        var make = "NIKON CORPORATION"
        var model = "NIKON Z 6"
        var cameraName = "Nikon Z 6"
        var lens = "NIKKOR Z 24-70mm f/4 S"
        var prettyName = "Nikon NIKKOR Z 24-70mm f/4 S"
        var raw = true
        var focalLength = 24.0
        var apertureValue = 4.0
        var focusDistance = 3.0
        var sensorFormatFactor: Double?
        /// fx and fy over the larger side; nil leaves them out.
        var focal: Double? = 0.68
        var distortion = SIMD3(-0.12, 0.05, -0.01)
        /// Green's own distortion, and red's and blue's relative to it.
        var colour = true
        var vignette: SIMD3<Double>? = SIMD3(-0.6, 0.15, -0.02)
        var fisheye = false

        fileprivate var fields: [Field] {
            var fields: [Field] = [
                .value("Make", make), .value("Model", model), .value("CameraPrettyName", cameraName),
                .value("Lens", lens), .value("LensPrettyName", prettyName),
                .value("ProfileName", "Synthetic (\(prettyName))"), .value("ImageWidth", "6000"),
                .value("ImageLength", "4000"), .value("FocalLength", "\(focalLength)"),
                .value("ApertureValue", "\(apertureValue)"), .value("FocusDistance", "\(focusDistance)"),
                .value("CameraRawProfile", raw ? "True" : "False"),
            ]
            if let sensorFormatFactor {
                fields.append(.value("SensorFormatFactor", "\(sensorFormatFactor)"))
            }
            var geometry = [Field.value("Version", "2")] + model("RadialDistortParam", distortion)
                + [.value("TangentialDistortParam1", "0.0003"), .value("TangentialDistortParam2", "-0.0002")]
            if colour {
                geometry += [
                    .model("ChromaticGreenModel", model("RadialDistortParam", SIMD3(-0.121, 0.051, -0.011))),
                    .model(
                        "ChromaticRedGreenModel",
                        model("RadialDistortParam", SIMD3(0.0008, -0.0004, 0), scale: 1.0004),
                    ),
                    .model(
                        "ChromaticBlueGreenModel",
                        model("RadialDistortParam", SIMD3(-0.0006, 0.0002, 0), scale: 0.9997),
                    ),
                ]
            }
            if let vignette {
                geometry.append(.model("VignetteModel", model("VignetteModelParam", vignette)))
            }
            return fields + [.model(fisheye ? "FisheyeModel" : "PerspectiveModel", geometry)]
        }

        private func model(_ coefficients: String, _ values: SIMD3<Double>, scale: Double? = nil) -> [Field] {
            var fields: [Field] = []
            if let focal {
                fields += [.value("FocalLengthX", "\(focal)"), .value("FocalLengthY", "\(focal)")]
            }
            fields += [.value("ImageXCenter", "0.51"), .value("ImageYCenter", "0.32")]
            if let scale {
                fields.append(.value("ScaleFactor", "\(scale)"))
            }
            return fields + (0 ..< 3).map { .value("\(coefficients)\($0 + 1)", "\(values[$0])") }
        }
    }

    fileprivate enum Field {
        case value(String, String)
        case model(String, [Field])
    }

    private static let cameraProfile = "http://ns.adobe.com/photoshop/1.0/camera-profile"

    /// An LCP file listing `specs`, `prefix` naming the camera profile namespace.
    static func file(_ specs: [Spec], form: Form = .elements, prefix: String = "stCamera") -> Data {
        let items = specs.map { spec in
            switch form {
            case .elements: #"<rdf:li rdf:parseType="Resource">"# + elements(spec.fields, prefix) + "</rdf:li>"
            case .attributes: "<rdf:li>" + description(spec.fields, prefix) + "</rdf:li>"
            }
        }
        let declaration = form == .elements ? #" xmlns:\#(prefix)="\#(cameraProfile)""# : ""
        return Data("""
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"\(declaration)>
           <photoshop:CameraProfiles>
            <rdf:Seq>
            \(items.joined(separator: "\n"))
            </rdf:Seq>
           </photoshop:CameraProfiles>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """.utf8)
    }

    /// Values and models as elements, models with `rdf:parseType="Resource"`.
    private static func elements(_ fields: [Field], _ prefix: String) -> String {
        fields.map { field in
            switch field {
            case let .value(name, value):
                "<\(prefix):\(name)>\(value)</\(prefix):\(name)>"
            case let .model(name, fields):
                #"<\#(prefix):\#(name) rdf:parseType="Resource">"# + elements(fields, prefix) + "</\(prefix):\(name)>"
            }
        }.joined(separator: "\n")
    }

    /// Values as attributes and models as nested descriptions, each declaring the namespace.
    private static func description(_ fields: [Field], _ prefix: String) -> String {
        var attributes = [#"xmlns:\#(prefix)="\#(cameraProfile)""#]
        var models: [String] = []
        for field in fields {
            switch field {
            case let .value(name, value):
                attributes.append(#"\#(prefix):\#(name)="\#(value)""#)
            case let .model(name, fields):
                models.append("<\(prefix):\(name)>" + description(fields, prefix) + "</\(prefix):\(name)>")
            }
        }
        return "<rdf:Description \(attributes.joined(separator: "\n"))>" + models.joined() + "</rdf:Description>"
    }
}
