import Foundation
import LibRaw
import RedlampEngineAPI

/// Decodes camera raw files through LibRaw.
///
/// Only LibRaw's unpacking is used: black levels, white balance, demosaicing and color
/// are all done by Redlamp's own GPU pipeline.
enum RawDecoder {
    static func decode(_ url: URL) throws -> DecodedImage {
        try decode(url: url, data: nil) { raw in
            url.withUnsafeFileSystemRepresentation { libraw_open_file(raw, $0) }
        }
    }

    /// The same from the file's bytes (as the decode service gets them), `url` naming the file.
    static func decode(_ data: Data, url: URL) throws -> DecodedImage {
        try data.withUnsafeBytes { bytes in
            try decode(url: url, data: data) { raw in libraw_open_buffer(raw, bytes.baseAddress, bytes.count) }
        }
    }

    /// `open` hands the file to LibRaw; `data` is the file's bytes when they're already in memory.
    private static func decode(
        url: URL,
        data: Data?,
        open: (UnsafeMutablePointer<libraw_data_t>) -> Int32,
    ) throws -> DecodedImage {
        guard let raw = libraw_init(0) else { throw EngineError.decodeFailed("LibRaw failed to initialise") }
        defer { libraw_close(raw) }

        try check(open(raw), url: url)
        let jpegXL = try unpack(raw, url: url, data: data)

        let sizes = raw.pointee.sizes
        let width = Int(sizes.width)
        let height = Int(sizes.height)
        let top = Int(sizes.top_margin)
        let left = Int(sizes.left_margin)
        let pitch = Int(sizes.raw_pitch)
        guard width > 0, height > 0 else { throw EngineError.decodeFailed("empty image") }

        let filters = raw.pointee.idata.filters
        let colors = Int(raw.pointee.idata.colors)
        let black = Float(raw.pointee.color.black)
        let nominalWhite = Float(raw.pointee.color.maximum)
        var whiteLevel = nominalWhite

        let layout: DecodedImage.Layout
        let samples: [UInt16]
        let blackLevels: [Float]
        var banding: BandingCorrection?
        var mosaic: MosaicMeasures?

        if let jpegXL {
            layout = .linearRGB
            samples = try cropped(jpegXL, to: sizes)
            blackLevels = (0 ..< 3).map { black + Float(rl_cblack(raw, Int32($0))) }
        } else if let rawImage = raw.pointee.rawdata.raw_image, filters != 0 {
            let pattern = try cfaPattern(raw, filters: filters)
            layout = .mosaic(pattern)
            var histogram = [UInt32](repeating: 0, count: 65536)
            // LibRaw applies a Phase One back's black levels and calibration only in raw2image: its
            // unpacked data and margins still hold the black it reports as subtracted.
            let phaseOne = raw.pointee.color.phase_one_data.format != 0
            samples = try phaseOne
                ? correctedPhaseOneMosaic(raw, filters: filters, url: url, histogram: &histogram)
                : copyMosaic(
                    rawImage, width: width, height: height, top: top, left: left,
                    pitchBytes: pitch, histogram: &histogram,
                )
            whiteLevel = histogram.withUnsafeBufferPointer {
                WhiteLevel.measured(histogram: $0, nominal: whiteLevel, total: width * height)
            }
            blackLevels = CanonOpticalBlack.checked(
                raw, stated: blackPattern(raw, filters: filters, pattern: pattern, base: black),
                pattern: pattern, white: whiteLevel,
            )
            let patternBlack = { [blackLevels] (x: Int, y: Int) -> Float in
                let column = (x % pattern.width + pattern.width) % pattern.width
                let row = (y % pattern.height + pattern.height) % pattern.height
                return blackLevels[row * pattern.width + column]
            }
            banding = phaseOne ? nil : OpticalBlack.measure(
                raw: rawImage, pitch: pitch / MemoryLayout<UInt16>.size, top: top, left: left,
                width: width, height: height, white: whiteLevel, black: patternBlack,
            )
            mosaic = MosaicMeasures(
                samples: samples, histogram: histogram, width: width, height: height, blackLevels: blackLevels,
                white: whiteLevel, margin: phaseOne ? nil : OpticalBlack.marginLevel(
                    raw: rawImage, pitch: pitch / MemoryLayout<UInt16>.size, top: top, left: left,
                    width: width, height: height, white: whiteLevel, black: patternBlack,
                ),
            )
        } else if colors >= 3, let pixels = raw.pointee.rawdata.color3_image {
            layout = .linearRGB
            samples = copyRGB(
                UnsafeRawPointer(pixels), channels: 3, width: width, height: height,
                top: top, left: left, pitchBytes: pitch,
            )
            blackLevels = (0 ..< 3).map { black + Float(rl_cblack(raw, Int32($0))) }
        } else if colors >= 3, let pixels = raw.pointee.rawdata.color4_image {
            layout = .linearRGB
            samples = copyRGB(
                UnsafeRawPointer(pixels), channels: 4, width: width, height: height,
                top: top, left: left, pitchBytes: pitch,
            )
            blackLevels = (0 ..< 3).map { black + Float(rl_cblack(raw, Int32($0))) }
        } else {
            throw EngineError.unsupportedFile(url.lastPathComponent)
        }

        var asShot = SIMD3<Double>((0 ..< 3).map { Double(rl_cam_mul(raw, Int32($0))) })
        if asShot.x <= 0 || asShot.y <= 0 || asShot.z <= 0 {
            asShot = SIMD3((0 ..< 3).map { Double(rl_pre_mul(raw, Int32($0))) })
        }
        if asShot.y > 0, (asShot / asShot.y * 0).sum() == 0 {
            asShot /= asShot.y
        } else {
            asShot = SIMD3(1, 1, 1)
        }

        let rgbCam = (0 ..< 3).flatMap { row in
            (0 ..< 3).map { col in Double(rl_rgb_cam(raw, Int32(row), Int32(col))) }
        }
        let cameraToSRGB = rgbCam.allSatisfy(\.isFinite) ? rgbCam : DNGColorCalibration.identity
        var xyzToCamera = (0 ..< 3).flatMap { row in
            (0 ..< 3).map { col in Double(rl_cam_xyz(raw, Int32(row), Int32(col))) }
        }
        if !xyzToCamera.contains(where: { $0 != 0 }) {
            xyzToCamera = dngColorMatrix(raw) ?? xyzToCamera
        }

        let other = raw.pointee.other
        let orientation = Int(sizes.flip)
        let orientedSize = orientation == 5 || orientation == 6
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)
        var info = ImageInfo(
            url: url,
            pixelSize: orientedSize,
            isRaw: true,
            sensorDescription: sensorDescription(layout),
            make: string(rl_make(raw)),
            model: string(rl_model(raw)),
            lens: string(rl_lens(raw)),
            iso: other.iso_speed > 0 ? Double(other.iso_speed) : nil,
            exposureTime: other.shutter > 0 ? Double(other.shutter) : nil,
            aperture: other.aperture > 0 ? Double(other.aperture) : nil,
            focalLength: other.focal_len > 0 ? Double(other.focal_len) : nil,
            captureDate: other.timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(other.timestamp)) : nil,
        )
        info.diagnostics = diagnostics(
            raw, url: url, blackLevels: blackLevels, nominalWhite: nominalWhite, white: whiteLevel,
            xyzToCamera: xyzToCamera, mosaic: mosaic,
        )

        var decoded = DecodedImage(
            width: width,
            height: height,
            layout: layout,
            samples: samples,
            blackLevels: blackLevels,
            whiteLevel: whiteLevel,
            asShotMultipliers: asShot,
            cameraToSRGB: cameraToSRGB,
            xyzToCamera: xyzToCamera.contains { $0 != 0 } && xyzToCamera.allSatisfy(\.isFinite) ? xyzToCamera : nil,
            orientation: [0, 3, 5, 6].contains(orientation) ? orientation : 0,
            baselineExposure: plausibleBaselineExposure(rl_baseline_exposure(raw)),
            info: info,
        )
        if let data = data ?? (try? Data(contentsOf: url, options: .alwaysMapped)) {
            decoded.noiseProfile = DNGNoiseProfile.read(data, url: url)
            decoded.gainMaps = DNGGainMaps.read(data, url: url)
            decoded.dngColor = DNGColorCalibration.read(data, url: url)
            decoded.dngProfile = DNGProfile.read(data, url: url)
            decoded.lensCorrection = LensCorrectionReader.read(data, url: url, orientation: decoded.orientation)
        }
        decoded.banding = banding
        return decoded
    }

    // MARK: - Helpers

    /// Unpacks the sensor data into LibRaw, or returns the JPEG XL raw image LibRaw can't read.
    /// A failed unpack clears everything LibRaw read, so JPEG XL is caught before unpacking, and
    /// Nikon's High Efficiency data before LibRaw decodes it into noise.
    private static func unpack(
        _ raw: UnsafeMutablePointer<libraw_data_t>,
        url: URL,
        data: Data?,
    ) throws -> DNGJPEGXL.Image? {
        let rawSize = PixelSize(width: Int(raw.pointee.sizes.raw_width), height: Int(raw.pointee.sizes.raw_height))
        if raw.pointee.idata.dng_version != 0,
           let image = try data.map({ try DNGJPEGXL.decode($0, rawSize: rawSize) })
           ?? DNGJPEGXL.decode(url, rawSize: rawSize) {
            return image
        }
        if NikonHighEfficiency.libRawCantDecode(raw, data: data, url: url) {
            throw NikonHighEfficiency.refusal
        }
        try check(libraw_unpack(raw), url: url)
        return nil
    }

    /// The JPEG XL image cropped to the ActiveArea LibRaw read.
    private static func cropped(_ image: DNGJPEGXL.Image, to sizes: libraw_image_sizes_t) throws -> [UInt16] {
        guard image.width == Int(sizes.raw_width), image.height == Int(sizes.raw_height) else {
            throw EngineError.decodeFailed("the JPEG XL image size doesn't match the DNG's")
        }
        return image.samples.withUnsafeBytes { stored in
            copyRGB(
                stored.baseAddress!, channels: 3, width: Int(sizes.width), height: Int(sizes.height),
                top: Int(sizes.top_margin), left: Int(sizes.left_margin),
                pitchBytes: image.width * 3 * MemoryLayout<UInt16>.size,
            )
        }
    }

    /// A DNG's own ColorMatrix, preferring the D65 calibration (EXIF LightSource 21), scaled by
    /// the AnalogBalance gains already applied to the stored values (XYZ → camera = AB · CM).
    /// LibRaw leaves `cam_xyz` empty for some DNGs, notably linear (ProRAW) files.
    private static func dngColorMatrix(_ raw: UnsafeMutablePointer<libraw_data_t>) -> [Double]? {
        let d65: Int32 = 21
        let order: [Int32] = rl_dng_illuminant(raw, 0) == d65 ? [0, 1] : [1, 0]
        let balance = raw.pointee.color.dng_levels.analogbalance
        let gains = [balance.0, balance.1, balance.2].map { $0 > 0 ? Double($0) : 1 }
        for index in order {
            let matrix = (0 ..< 3).flatMap { row in
                (0 ..< 3).map { col in gains[row] * Double(rl_dng_colormatrix(raw, index, Int32(row), Int32(col))) }
            }
            if matrix.contains(where: { $0 != 0 }) {
                return matrix
            }
        }
        return nil
    }

    /// LibRaw reports a large negative sentinel when a file has no DNG BaselineExposure.
    private static func plausibleBaselineExposure(_ value: Float) -> Double {
        value.isFinite && abs(value) <= 10 ? Double(value) : 0
    }

    private static func check(_ status: Int32, url: URL) throws {
        guard status == 0 else {
            let reason = String(cString: libraw_strerror(status))
            if status == -2 {
                throw EngineError.unsupportedFile(url.lastPathComponent)
            }
            throw EngineError.decodeFailed(reason)
        }
    }

    static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let value = String(cString: pointer).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// LibRaw's `FC(row, col)` for 2x2 Bayer patterns, with G2 folded into green.
    private static func bayerColor(_ filters: UInt32, row: Int, col: Int) -> Int {
        let shift = UInt32((((row << 1) & 14) | (col & 1)) << 1)
        return Int((filters >> shift) & 3)
    }

    static func cfaPattern(_ raw: UnsafeMutablePointer<libraw_data_t>, filters: UInt32) throws -> CFAPattern {
        if filters == 9 {
            let colors = (0 ..< 36).map { UInt8(clamping: rl_xtrans(raw, Int32($0 / 6), Int32($0 % 6))) }
            return CFAPattern(width: 6, height: 6, colors: colors)
        }
        guard filters > 1000 else { throw EngineError.decodeFailed("unsupported color filter layout") }
        let colors = (0 ..< 4).map { index -> UInt8 in
            let color = bayerColor(filters, row: index / 2, col: index % 2)
            return UInt8(color == 3 ? 1 : color)
        }
        return CFAPattern(width: 2, height: 2, colors: colors)
    }

    /// Black level for each position of the CFA pattern: the global black, the per-channel
    /// offset and LibRaw's spatial black pattern.
    private static func blackPattern(
        _ raw: UnsafeMutablePointer<libraw_data_t>,
        filters: UInt32,
        pattern: CFAPattern,
        base: Float,
    ) -> [Float] {
        let patternRows = Int(rl_cblack(raw, 4))
        let patternCols = Int(rl_cblack(raw, 5))
        return (0 ..< pattern.width * pattern.height).map { index in
            let row = index / pattern.width
            let col = index % pattern.width
            let channel = filters == 9 ? Int(pattern.colors[index]) : bayerColor(filters, row: row, col: col)
            var level = base + Float(rl_cblack(raw, Int32(channel)))
            if patternRows > 0, patternCols > 0 {
                let offset = 6 + (row % patternRows) * patternCols + (col % patternCols)
                level += Float(rl_cblack(raw, Int32(offset)))
            }
            return level
        }
    }

    private static func copyMosaic(
        _ source: UnsafeMutablePointer<UInt16>,
        width: Int,
        height: Int,
        top: Int,
        left: Int,
        pitchBytes: Int,
        histogram: inout [UInt32],
    ) -> [UInt16] {
        let stride = pitchBytes / MemoryLayout<UInt16>.size
        return histogram.withUnsafeMutableBufferPointer { counts in
            [UInt16](unsafeUninitializedCapacity: width * height) { buffer, count in
                for y in 0 ..< height {
                    let row = source + (y + top) * stride + left
                    let destination = buffer.baseAddress! + y * width
                    destination.update(from: row, count: width)
                    for x in 0 ..< width {
                        counts[Int(row[x])] &+= 1
                    }
                }
                count = width * height
            }
        }
    }

    /// A Phase One mosaic from LibRaw's `raw2image`, which subtracts the back's black levels
    /// (global, per row and per column) and applies its flat-field and sensor-half corrections.
    private static func correctedPhaseOneMosaic(
        _ raw: UnsafeMutablePointer<libraw_data_t>,
        filters: UInt32,
        url: URL,
        histogram: inout [UInt32],
    ) throws -> [UInt16] {
        try check(libraw_raw2image(raw), url: url)
        defer { libraw_free_image(raw) }
        guard let image = raw.pointee.image else { throw EngineError.decodeFailed("LibRaw returned no image") }
        let sizes = raw.pointee.sizes
        let width = Int(sizes.width)
        let height = Int(sizes.height)
        let stride = Int(sizes.iwidth)
        guard stride == width, Int(sizes.iheight) == height else {
            throw EngineError.decodeFailed("LibRaw shrank the Phase One image")
        }
        // LibRaw's `filters` repeats every 8 rows and 2 columns; each photosite's value sits in
        // its own colour's channel of the 4-channel image.
        let channels = (0 ..< 16).map { bayerColor(filters, row: $0 >> 1, col: $0 & 1) }
        let values = UnsafeRawPointer(image).assumingMemoryBound(to: UInt16.self)
        return histogram.withUnsafeMutableBufferPointer { counts in
            [UInt16](unsafeUninitializedCapacity: width * height) { buffer, count in
                for y in 0 ..< height {
                    let row = values + y * stride * 4
                    let destination = buffer.baseAddress! + y * width
                    let phase = (y & 7) << 1
                    for x in 0 ..< width {
                        let value = row[x * 4 + channels[phase | (x & 1)]]
                        destination[x] = value
                        counts[Int(value)] &+= 1
                    }
                }
                count = width * height
            }
        }
    }

    private static func copyRGB(
        _ source: UnsafeRawPointer,
        channels: Int,
        width: Int,
        height: Int,
        top: Int,
        left: Int,
        pitchBytes: Int,
    ) -> [UInt16] {
        [UInt16](unsafeUninitializedCapacity: width * height * 3) { buffer, count in
            for y in 0 ..< height {
                let row = (source + (y + top) * pitchBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0 ..< width {
                    let from = row + (x + left) * channels
                    let to = buffer.baseAddress! + (y * width + x) * 3
                    to[0] = from[0]
                    to[1] = from[1]
                    to[2] = from[2]
                }
            }
            count = width * height * 3
        }
    }

    private static func sensorDescription(_ layout: DecodedImage.Layout) -> String {
        switch layout {
        case let .mosaic(pattern): pattern.description
        case .linearRGB: "Linear DNG"
        case .linearSRGBHalf: "Bitmap"
        case .balancedCameraHalf: "Focus stack"
        }
    }
}
