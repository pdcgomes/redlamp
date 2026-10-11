import Foundation

/// The two lens fields the library indexes for the traits Wide Open, Telephoto and Ultra Wide (LIB-06): the widest
/// aperture the lens had at the photo's focal length, and the focal length in 35 mm terms.
enum LensOptics {
    /// The widest f-number the lens had at `focal`, in millimetres: what its name says (`f/1.8`, `F2.8`, `1:2`, or a
    /// zoom's `F3.5-5.6` over its focal lengths), else EXIF's lens specification (minimum and maximum focal lengths,
    /// then the widest f-number at each, 0 where the camera doesn't know it), else EXIF's MaxApertureValue, `apex`.
    /// ImageIO gives a few formats' MaxApertureValue as an f-number rather than in APEX units (Canon's CR2 and
    /// Hasselblad's FFF), so it's read last, and only where the photo's own `aperture` isn't wider. A zoom whose
    /// widest aperture closes as it zooms in takes MaxApertureValue where it lies within the zoom's range, which
    /// cameras write for the focal length used, and otherwise its range in stops over the logarithm of the focal
    /// length. To the hundredth, as the column store keeps apertures; nil when nothing says.
    static func widestAperture(
        lens: String?, specification: [Double] = [], apex: Double? = nil, focal: Double?, aperture: Double? = nil,
    ) -> Double? {
        unrounded(lens: lens, specification: specification, apex: apex, focal: focal, aperture: aperture)
            .map { ($0 * 100).rounded() / 100 }
    }

    private static func unrounded(
        lens: String?, specification: [Double], apex: Double?, focal: Double?, aperture: Double?,
    ) -> Double? {
        let maximum = apex.flatMap(fNumber(apex:))
        let named = lens.map(LensName.init)
        var focals = named?.focals
        var range = named?.apertures
        if range == nil, specification.count == 4, specification[2] > 0 {
            let (short, long) = (specification[0], specification[1])
            let isPrime = short <= 0 || long <= short
            range = (specification[2], isPrime || specification[3] <= 0 ? specification[2] : specification[3])
            focals = isPrime ? nil : short ... long
        }
        guard let (wide, narrow) = range else {
            guard let maximum, aperture.map({ maximum <= $0 * thirdStop }) ?? true else { return nil }
            return maximum
        }
        if narrow <= wide * 1.005 {
            return wide
        }
        if let maximum, maximum >= wide / thirdStop, maximum <= narrow * thirdStop {
            return maximum
        }
        guard let focals, focals.lowerBound > 0, focals.upperBound > focals.lowerBound else {
            return named?.isPrime == true ? wide : nil
        }
        guard let focal, focal > 0 else { return nil }
        let clamped = min(max(focal, focals.lowerBound), focals.upperBound)
        let along = log(clamped / focals.lowerBound) / log(focals.upperBound / focals.lowerBound)
        return wide * pow(narrow / wide, along)
    }

    /// A third of a stop in f-number, the finest step most cameras set an aperture in.
    static let thirdStop = pow(2, 1.0 / 6)

    /// An APEX aperture value's f-number, between f/0.5 and f/64; nil outside.
    static func fNumber(apex: Double) -> Double? {
        let number = pow(2, apex / 2)
        return number.isFinite && number >= 0.5 && number <= 64 ? number : nil
    }

    /// The focal length in 35 mm terms, to the whole millimetre as EXIF's FocalLengthIn35mmFilm has it: that tag,
    /// `written`, where the camera writes it; else `focal` times the crop factor of the camera's `make` and `model`
    /// (`cropFactor`), for the cameras known to write neither the tag nor a focal plane resolution to trust; else
    /// `focal` times the crop factor `focalPlane` gives. Nil when none says.
    static func focal35(
        written: Double?, focal: Double?, make: String?, model: String?, focalPlane: FocalPlane? = nil,
    ) -> Double? {
        if let written, written >= 1, written < 100_000 {
            return written.rounded()
        }
        guard let focal, focal > 0, focal.isFinite,
              let crop = cropFactor(make: make, model: model) ?? focalPlane?.cropFactor
        else { return nil }
        return (focal * crop).rounded()
    }

    /// EXIF's focal plane resolution, the pixels in a unit of the sensor's width and height, and the image those
    /// pixels are of: the sensor's size and so its crop factor.
    struct FocalPlane: Sendable, Hashable {
        var xResolution: Double
        var yResolution: Double
        /// EXIF's FocalPlaneResolutionUnit: 2 inches, 3 centimetres, 4 millimetres, 5 micrometres.
        var unit: Int
        var width: Int
        var height: Int

        /// The diagonal of the 36 × 24 mm frame over the sensor's; nil for a sensor under 4 mm or over 90 mm across,
        /// which no camera has.
        var cropFactor: Double? {
            let millimetres: Double
            switch unit {
            case 2: millimetres = 25.4
            case 3: millimetres = 10
            case 4: millimetres = 1
            case 5: millimetres = 0.001
            default: return nil
            }
            guard xResolution > 0, yResolution > 0, width > 0, height > 0 else { return nil }
            let diagonal = hypot(Double(width) / xResolution * millimetres, Double(height) / yResolution * millimetres)
            guard diagonal >= 4, diagonal <= 90 else { return nil }
            return LensOptics.fullFrameDiagonal / diagonal
        }
    }

    /// The diagonal of the 36 × 24 mm frame, in millimetres.
    static let fullFrameDiagonal = (36.0 * 36 + 24 * 24).squareRoot()

    // MARK: - Cameras

    /// The crop factor of the cameras that write neither EXIF's 35 mm focal length nor a focal plane resolution to
    /// trust, from their make and model as the file writes them: Canon's EOS bodies (full frame, APS-H or APS-C;
    /// the 5D Mark IV's focal plane resolution makes its sensor 29.8 mm wide), Olympus's and OM System's Four Thirds
    /// bodies, Leica's, and Phase One's IQ backs. Nil for any other camera.
    static func cropFactor(make: String?, model: String?) -> Double? {
        let make = (make ?? "").uppercased()
        let model = (model ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        if make.hasPrefix("CANON") {
            return canon(model)
        }
        if make.hasPrefix("OLYMPUS") || make.hasPrefix("OM DIGITAL") || make.hasPrefix("OM SYSTEM") {
            return ["E-", "PEN", "OM-"].contains { model.hasPrefix($0) } ? 2 : nil
        }
        if make.hasPrefix("LEICA") {
            return leica(model)
        }
        if make.hasPrefix("PHASE ONE") {
            guard model.hasPrefix("IQ") else { return nil }
            return model.hasSuffix(" 50MP") || model.contains("IQ150") || model.contains("IQ250") ? 0.79 : 0.65
        }
        return nil
    }

    /// An EOS body's: full frame for the 5D, 6D, 1Ds, 1D X and 1D C lines and the R, Ra, RP, R1, R3, R5, R6 and R8;
    /// APS-H for the other 1D bodies; APS-C for the rest. Nil for Canon's compacts.
    private static func canon(_ model: String) -> Double? {
        var name = Substring(model)
        if name.hasPrefix("CANON") {
            name = name.dropFirst(5)
        }
        name = name.drop { $0 == " " }
        guard name.hasPrefix("EOS") else { return nil }
        name = name.dropFirst(3).drop { $0 == " " || $0 == "-" }
        if ["5D", "6D", "1DS", "1D X", "1DX", "1D C"].contains(where: { name.hasPrefix($0) })
            || ["R", "RA", "RP"].contains(String(name)) {
            return 1
        }
        if name.count >= 2, name.first == "R", let digit = name.dropFirst().first, "13568".contains(digit),
           name.dropFirst(2).first?.isNumber != true {
            return 1
        }
        return name.hasPrefix("1D") ? 1.3 : 1.6
    }

    /// A Leica's: full frame for the M (but the M8's 1.33), Q and SL; 0.79 for the S's 45 × 30 mm; APS-C for the
    /// CL, T, TL and X. Nil for the others, made with Panasonic, which write the tag.
    private static func leica(_ model: String) -> Double? {
        let name = model.hasPrefix("LEICA ") ? String(model.dropFirst(6)) : model
        if name.hasPrefix("M8") {
            return 1.33
        }
        if name.hasPrefix("M") || name.hasPrefix("Q") || name.hasPrefix("SL") {
            return 1
        }
        if name.hasPrefix("S") {
            return 0.79
        }
        return ["CL", "T", "X"].contains { name.hasPrefix($0) } ? 1.53 : nil
    }
}

/// What a lens's name says of its focal lengths and widest apertures, as cameras write it to EXIF: "XF18-55mmF2.8-4
/// R LM OIS" is 18 to 55 mm, f/2.8 at 18 mm and f/4 at 55; "Summicron-M 1:2/50" is f/2; "FE 85mm F1.8" is 85 mm at
/// f/1.8; "LUMIX G VARIO 12-32/F3.5-5.6" is 12 to 32 mm, f/3.5 to f/5.6.
struct LensName: Sendable {
    /// The widest f-number at its shortest focal length, then at its longest; nil when the name gives none.
    var apertures: (Double, Double)?
    /// A zoom's focal lengths, in millimetres; nil when the name gives no range.
    var focals: ClosedRange<Double>?
    /// It names one focal length and no range.
    var isPrime = false

    init(_ name: String) {
        let bytes = Array(name.utf8)
        var index = 0
        var firstNumber: (end: Int, value: Double)?
        while index < bytes.count {
            if apertures == nil, let (aperture, end) = Self.aperture(in: bytes, at: index) {
                apertures = aperture
                index = end
                continue
            }
            guard let (value, end) = Self.number(in: bytes, at: index), index == 0 || !Self.isDigit(bytes[index - 1])
            else {
                index += 1
                continue
            }
            if focals == nil, end < bytes.count, bytes[end] == UInt8(ascii: "-"),
               let (upper, after) = Self.number(in: bytes, at: end + 1), upper > value, value > 0,
               Self.endsFocal(bytes, at: after) {
                focals = value ... upper
                index = after
                continue
            }
            if firstNumber == nil, Self.endsFocal(bytes, at: end) {
                firstNumber = (end, value)
            }
            index = end
        }
        isPrime = focals == nil && firstNumber != nil
    }

    /// The aperture written at `index`: `f/2.8`, `F2.8`, `f2.8`, `1:2` and a range after it, `F3.5-5.6`, and where it
    /// ends. An `f` after a letter other than an `m` (`XF35mm`, `EF50mm`) isn't one, nor a number with `mm` after it.
    private static func aperture(in bytes: [UInt8], at index: Int) -> ((Double, Double), Int)? {
        var start: Int
        let byte = bytes[index]
        if byte == UInt8(ascii: "f") || byte == UInt8(ascii: "F") {
            if index > 0 {
                let before = bytes[index - 1]
                let isLetter = (before | 0x20) >= UInt8(ascii: "a") && (before | 0x20) <= UInt8(ascii: "z")
                guard !isDigit(before), !isLetter || (before | 0x20) == UInt8(ascii: "m") else { return nil }
            }
            start = index + 1
            if start < bytes.count, bytes[start] == UInt8(ascii: "/") {
                start += 1
            }
        } else if byte == UInt8(ascii: "1"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: ":"),
                  index == 0 || !isDigit(bytes[index - 1]) {
            start = index + 2
        } else {
            return nil
        }
        guard let (wide, end) = number(in: bytes, at: start), wide >= 0.5, wide <= 64, !endsInMillimetres(
            bytes,
            at: end,
        )
        else { return nil }
        if end < bytes.count, bytes[end] == UInt8(ascii: "-"), let (narrow, after) = number(in: bytes, at: end + 1),
           narrow > wide, narrow <= 64, !endsInMillimetres(bytes, at: after) {
            return ((wide, narrow), after)
        }
        return ((wide, wide), end)
    }

    /// The decimal number at `index` (`2`, `2.8`, `18.3`), and where it ends.
    private static func number(in bytes: [UInt8], at index: Int) -> (Double, Int)? {
        var end = index
        while end < bytes.count, isDigit(bytes[end]), end - index < 6 {
            end += 1
        }
        guard end > index else { return nil }
        if end + 1 < bytes.count, bytes[end] == UInt8(ascii: "."), isDigit(bytes[end + 1]) {
            end += 1
            while end < bytes.count, isDigit(bytes[end]), end - index < 12 {
                end += 1
            }
        }
        return String(bytes: bytes[index ..< end], encoding: .ascii).flatMap { Double($0) }.map { ($0, end) }
    }

    /// Whether a focal length can end at `index`: in `mm`, a space, a `/`, or the name's end.
    private static func endsFocal(_ bytes: [UInt8], at index: Int) -> Bool {
        index == bytes.count || bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: "/")
            || endsInMillimetres(bytes, at: index)
    }

    private static func endsInMillimetres(_ bytes: [UInt8], at index: Int) -> Bool {
        var at = index
        while at < bytes.count, bytes[at] == UInt8(ascii: " ") {
            at += 1
        }
        return at + 1 < bytes
            .count && bytes[at] | 0x20 == UInt8(ascii: "m") && bytes[at + 1] | 0x20 == UInt8(ascii: "m")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
