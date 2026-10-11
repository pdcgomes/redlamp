import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RedlampLibrary

/// The lens's widest aperture and the 35 mm focal length the library indexes for the traits Wide Open, Telephoto
/// and Ultra Wide (LIB-06): from the lens's name, EXIF's lens specification, MaxApertureValue and 35 mm focal
/// length, the crop factors of the cameras that write neither, and the focal plane's size.
struct LensOpticsTests {
    @Test(arguments: [
        ("FE 85mm F1.8", 85.0, 1.8), ("XF35mmF1.4 R", 35, 1.4), ("XF16-55mmF2.8 R LM WR", 23, 2.8),
        ("EF50mm f/1.4 USM", 50, 1.4), ("AF-S NIKKOR 85mm f/1.8G", 85, 1.8), ("Summicron-M 1:2/50", 50, 2),
        ("SUMMILUX 28 f/1.7 ASPH.", 28, 1.7), ("LEICA DG SUMMILUX 15/F1.7", 15, 1.7),
        ("iPhone 12 Pro back triple camera 4.2mm f/1.6", 4.2, 1.6), ("Sony FE 85mm F1.8 (SEL85F18)", 85, 1.8),
        ("TAMRON SP 24-70mm F/2.8 Di VC USD G2 (A032)", 50, 2.8), ("RF85mm F1.2 L USM", 85, 1.2),
        ("7Artisans 35mm f/0.95", 35, 0.95), ("DJI FC3582 6.7mm f/1.7", 6.7, 1.7), ("GR LENS 18.3mm F2.8", 18.3, 2.8),
        ("VARIO-ELMARIT-SL 24-70 f/2.8 ASPH.", 35, 2.8), ("Sigma 24-70mm F2.8 IF EX DG HSM", 70, 2.8),
    ])
    func `a lens's name gives its widest aperture`(name: String, focal: Double, widest: Double) {
        #expect(LensOptics.widestAperture(lens: name, focal: focal) == widest)
    }

    @Test(arguments: ["24-70mm", "XCD 80", "XCD 38V", "0.0 mm f/0.0", "Batis 2/25", "FUJINON"])
    func `a name without an aperture gives none`(name: String) {
        #expect(LensOptics.widestAperture(lens: name, focal: 40) == nil)
    }

    @Test func `a zoom whose widest aperture closes as it zooms in goes in stops over the focal length's logarithm`(
    ) throws {
        let kit = "EF-S18-55mm f/3.5-5.6 IS STM"
        #expect(LensOptics.widestAperture(lens: kit, focal: 18) == 3.5)
        #expect(LensOptics.widestAperture(lens: kit, focal: 55) == 5.6)
        #expect(LensOptics.widestAperture(lens: kit, focal: 10) == 3.5, "below its range, its shortest")
        #expect(LensOptics.widestAperture(lens: kit, focal: nil) == nil)
        let middle = try #require(LensOptics.widestAperture(lens: kit, focal: 35))
        #expect(abs(middle - 4.630) < 0.001, "\(middle)")
        let camera = try #require(LensOptics.widestAperture(lens: kit, apex: 2 * log2(4.5), focal: 35))
        #expect(abs(camera - 4.5) < 0.0001, "the camera's MaxApertureValue, within the zoom's range")
        let outside = try #require(LensOptics.widestAperture(lens: kit, apex: 2 * log2(11), focal: 35))
        #expect(abs(outside - 4.630) < 0.001, "a MaxApertureValue outside the range is left out")
        #expect(LensOptics.widestAperture(lens: "LUMIX G VARIO 12-32/F3.5-5.6", focal: 32) == 5.6)
        #expect(LensOptics.widestAperture(lens: "XF18-55mmF2.8-4 R LM OIS", focal: 55) == 4)
        #expect(LensOptics.widestAperture(lens: "SAMYANG 35-150mm F2-2.8", focal: 35) == 2)
        #expect(LensOptics.widestAperture(lens: "Laowa 12mm f/2.8-22 Zero-D", focal: 12) == 2.8, "a prime's range")
    }

    @Test func `EXIF's lens specification gives it where the name doesn't, a prime's first aperture alone`() throws {
        #expect(LensOptics.widestAperture(lens: "24-70mm", specification: [24, 70, 0, 0], focal: 40) == nil)
        #expect(LensOptics.widestAperture(lens: nil, specification: [24, 24, 2.8, 11], focal: 12.29) == 2.8)
        #expect(LensOptics.widestAperture(lens: nil, specification: [24, 70, 4, 4], focal: 52) == 4)
        let zoom = try #require(LensOptics.widestAperture(lens: nil, specification: [16, 50, 2, 2.8], focal: 35))
        #expect(abs(zoom - 2.52) < 0.01, "\(zoom)")
        #expect(
            LensOptics.widestAperture(
                lens: "iPhone 12 Pro back triple camera 4.2mm f/1.6", specification: [1.54, 6, 1.6, 2.4], focal: 4.2,
            ) == 1.6,
            "the name's, over a phone's specification of its three cameras",
        )
    }

    @Test func `a MaxApertureValue alone is read in APEX units, unless the photo was shot wider than it says`() throws {
        let pixel = try #require(LensOptics.widestAperture(lens: nil, apex: 1.531069, focal: 4.38, aperture: 1.7))
        #expect(abs(pixel - 1.7) < 0.005, "\(pixel)")
        #expect(LensOptics.widestAperture(lens: nil, apex: 11.31, focal: 70, aperture: 4) == nil)
        #expect(LensOptics.widestAperture(lens: nil, apex: 40, focal: 70) == nil, "past f/64")
    }

    @Test func `the 35 mm focal length is EXIF's, else the camera's crop factor's, else the focal plane's`() {
        let canon5D = LensOptics.FocalPlane(
            xResolution: 268_800 / 47, yResolution: 2_240_000 / 391, unit: 2, width: 6720, height: 4480,
        )
        #expect(LensOptics.focal35(written: 53, focal: 35, make: "FUJIFILM", model: "X-T3") == 53)
        #expect(LensOptics.focal35(written: nil, focal: 200, make: "Canon", model: "Canon EOS R6") == 200)
        #expect(LensOptics.focal35(written: nil, focal: 50, make: "Canon", model: "Canon EOS 90D") == 80)
        #expect(
            LensOptics.focal35(
                written: nil,
                focal: 40,
                make: "Canon",
                model: "Canon EOS 5D Mark IV",
                focalPlane: canon5D,
            )
                == 40,
            "the table before the 5D Mark IV's focal plane, which makes it 48",
        )
        #expect(LensOptics.focal35(written: nil, focal: 40, make: "Canon", model: "PowerShot G7 X", focalPlane: canon5D)
            == 48)
        #expect(LensOptics.focal35(written: nil, focal: 25, make: "OM Digital Solutions", model: "OM-1MarkII  ") == 50)
        #expect(LensOptics.focal35(written: nil, focal: 50, make: "LEICA CAMERA AG", model: "LEICA M10-R") == 50)
        #expect(LensOptics.focal35(written: nil, focal: 45, make: "Phase One", model: "IQ4 150MP") == 29)
        let sigma = LensOptics.FocalPlane(
            xResolution: 4276.09,
            yResolution: 4276.09,
            unit: 2,
            width: 6000,
            height: 4000,
        )
        #expect(LensOptics.focal35(written: nil, focal: 45, make: "SIGMA", model: "fp", focalPlane: sigma) == 45)
        let fuji = LensOptics.FocalPlane(xResolution: 1882, yResolution: 1882, unit: 3, width: 4416, height: 2944)
        #expect(
            LensOptics.focal35(written: nil, focal: 35, make: "FUJIFILM", model: "X-T3", focalPlane: fuji) == 54,
            "23.5 × 15.6 mm, where the camera writes 53",
        )
        #expect(LensOptics
            .focal35(written: nil, focal: 18.3, make: "RICOH IMAGING COMPANY, LTD.", model: "GR III") == nil)
        #expect(LensOptics.focal35(written: nil, focal: nil, make: "Canon", model: "Canon EOS R6") == nil)
        let tiny = LensOptics.FocalPlane(xResolution: 100_000, yResolution: 100_000, unit: 2, width: 6000, height: 4000)
        #expect(tiny.cropFactor == nil, "a sensor 1.8 mm across is no camera's")
    }

    @Test(arguments: [
        ("Canon EOS R5", 1.0), ("Canon EOS R5m2", 1), ("Canon EOS R5 C", 1), ("Canon EOS R50", 1.6),
        ("Canon EOS R10", 1.6), ("Canon EOS R100", 1.6), ("Canon EOS R1", 1), ("Canon EOS R3", 1), ("Canon EOS RP", 1),
        ("Canon EOS R", 1), ("Canon EOS Ra", 1), ("Canon EOS R7", 1.6), ("Canon EOS R8", 1),
        ("Canon EOS R6 Mark III", 1), ("Canon EOS-1D X Mark III", 1), ("Canon EOS-1D C", 1),
        ("Canon EOS-1Ds Mark III", 1), ("Canon EOS-1D Mark IV", 1.3), ("Canon EOS-1D", 1.3),
        ("Canon EOS 5D Mark IV", 1), ("Canon EOS 5DS R", 1), ("Canon EOS 6D Mark II", 1), ("Canon EOS 90D", 1.6),
        ("Canon EOS DIGITAL REBEL XTi", 1.6), ("Canon EOS M50", 1.6), ("Canon EOS Kiss X10", 1.6),
    ])
    func `each of Canon's EOS bodies is full frame, APS-H or APS-C by its model`(model: String, crop: Double) {
        #expect(LensOptics.cropFactor(make: "Canon", model: model) == crop)
    }

    @Test func `the other cameras the table knows, and those it leaves to their files`() {
        #expect(LensOptics.cropFactor(make: "Canon", model: "Canon PowerShot G7 X Mark III") == nil)
        #expect(LensOptics.cropFactor(make: "OLYMPUS IMAGING CORP.", model: "E-M1MarkIII") == 2)
        #expect(LensOptics.cropFactor(make: "OLYMPUS CORPORATION", model: "PEN-F") == 2)
        #expect(LensOptics.cropFactor(make: "OLYMPUS CORPORATION", model: "TG-6") == nil)
        #expect(LensOptics.cropFactor(make: "LEICA CAMERA AG", model: "LEICA M8") == 1.33)
        #expect(LensOptics.cropFactor(make: "LEICA CAMERA AG", model: "LEICA Q2") == 1)
        #expect(LensOptics.cropFactor(make: "Leica Camera AG", model: "LEICA SL2") == 1)
        #expect(LensOptics.cropFactor(make: "Leica Camera AG", model: "LEICA S (Typ 007)") == 0.79)
        #expect(LensOptics.cropFactor(make: "Leica Camera AG", model: "LEICA CL") == 1.53)
        #expect(LensOptics.cropFactor(make: "Leica Camera AG", model: "LEICA D-LUX 7") == nil)
        #expect(LensOptics.cropFactor(make: "Phase One", model: "IQ3 50MP") == 0.79)
        #expect(LensOptics.cropFactor(make: "SONY", model: "ILCE-7M4") == nil)
        #expect(LensOptics.cropFactor(make: nil, model: nil) == nil)
    }

    // MARK: - Files

    /// The development samples, by name: the widest aperture and the 35 mm focal length each reads as.
    static let samples: [(name: String, widest: Double, focal35: Double)] = [
        ("_DSC0009.ARW", 2.8, 32), ("AFXT2720.RAF", 2, 53), ("Canon_EOS_R6_RAW_ISO_100_nocrop_nodual.CR3", 2.8, 200),
        ("DSC_0750.NEF", 4, 52), ("IMG_1361.DNG", 1.6, 26), ("PXL_20201121_100251397.dng", 1.70, 27),
    ]

    static let rawFolder = PhotoMetadataReaderTests.root.appending(path: "tests/fixtures/raw")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: rawFolder.path)))
    func `the development raws read their lens's widest aperture and their 35 mm focal length`() throws {
        for sample in Self.samples {
            let url = Self.rawFolder.appending(path: sample.name)
            let (head, size) = try PhotoMetadataReaderTests.head(of: url)
            let metadata = try #require(
                PhotoMetadataReader.read(head: head, fileSize: size, url: url),
                "\(sample.name)",
            )
            let widest = try #require(metadata.widestAperture, "\(sample.name)")
            #expect(abs(widest - sample.widest) < 0.005, "\(sample.name): \(widest)")
            #expect(metadata.focal35 == sample.focal35, "\(sample.name): \(metadata.focal35 ?? -1)")
        }
    }

    @Test func `a JPEG's lens specification and 35 mm focal length are read with the rest of its EXIF`() throws {
        var properties = PhotoMetadataReaderTests.cameraProperties
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifLensModel] = "Test Zoom"
        exif[kCGImagePropertyExifLensSpecification] = [24, 70, 2.8, 2.8]
        exif[kCGImagePropertyExifFocalLength] = 24
        exif[kCGImagePropertyExifFocalLenIn35mmFilm] = 36
        properties[kCGImagePropertyExifDictionary] = exif
        let jpeg = try PhotoMetadataReaderTests.encode(PhotoMetadataReaderTests.image(), properties: properties)
        let url = URL(fileURLWithPath: "/Volumes/Test/Photos/Lens.jpg")
        let metadata = try #require(PhotoMetadataReader.read(head: jpeg, fileSize: jpeg.count, url: url))
        #expect(
            metadata.widestAperture == 2.8 && metadata.focal35 == 36,
            "\(metadata.lens ?? "-") \(metadata.widestAperture ?? -1) \(metadata.focal35 ?? -1)",
        )

        exif.removeValue(forKey: kCGImagePropertyExifFocalLenIn35mmFilm)
        exif.removeValue(forKey: kCGImagePropertyExifLensSpecification)
        exif[kCGImagePropertyExifMaxApertureValue] = 2 * log2(2.8)
        properties[kCGImagePropertyExifDictionary] = exif
        properties[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS 90D",
        ]
        let canon = try PhotoMetadataReaderTests.encode(PhotoMetadataReaderTests.image(), properties: properties)
        let read = try #require(PhotoMetadataReader.read(head: canon, fileSize: canon.count, url: url))
        let widest = try #require(read.widestAperture)
        #expect(abs(widest - 2.8) < 0.01 && read.focal35 == 38, "\(widest) \(read.focal35 ?? -1)")
    }
}
