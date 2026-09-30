import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import simd
import UniformTypeIdentifiers

/// The encoding a third-party table was built for.
public enum ImportedTableSpace: String, Sendable, CaseIterable {
    /// sRGB-encoded sRGB, what almost every `.cube` and HaldCLUT file assumes.
    case sRGB
    /// Already Redlamp's own space (display Rec.2020, sRGB transfer).
    case displayRec2020
}

public enum LookTableImportError: Error, CustomStringConvertible, Equatable {
    case notACube(String)
    case unsupportedSize(Int)
    case notAHaldImage(width: Int, height: Int)
    case unreadableImage

    public var description: String {
        switch self {
        case let .notACube(reason): "not a .cube file: \(reason)"
        case let .unsupportedSize(size): "tables of \(size) points aren't supported (2 to 65)"
        case let .notAHaldImage(width, height): "a \(width)×\(height) image isn't a HaldCLUT (it must be level³ square)"
        case .unreadableImage: "the image can't be read"
        }
    }
}

public enum LookTableImport {
    /// Tables are stored at this size unless they are smaller.
    public static let storedSize = 33

    /// Re-expresses a table built for `space` in Redlamp's display Rec.2020 domain, so it
    /// renders as its author intended: colors are converted in, looked up, and back.
    public static func adapt(
        _ sample: (SIMD3<Float>) -> SIMD3<Float>,
        from space: ImportedTableSpace,
        size: Int,
    ) throws -> LookTable {
        switch space {
        case .displayRec2020:
            try LookTable(size: size, transform: sample)
        case .sRGB:
            try LookTable(size: size) { encoded2020 in
                let linear2020 = ColorMath.srgbDecode(encoded2020)
                let linear709 = ColorMath.rec2020ToRec709 * linear2020
                // Out-of-sRGB colors pass through the table's edge and keep their offset.
                let inside = simd_clamp(linear709, .zero, SIMD3(repeating: 1))
                let outside = linear709 - inside
                let looked = ColorMath.srgbDecode(sample(ColorMath.srgbEncode(inside)))
                let back = ColorMath.rec709ToRec2020 * (looked + outside)
                return ColorMath.srgbEncode(simd_max(back, .zero))
            }
        }
    }

    // MARK: - .cube

    public struct Cube: Sendable {
        public var title: String?
        public var table: LookTable
    }

    /// Parses Adobe/Resolve `.cube` text: 3D tables (and 1D ones, expanded to 3D), with
    /// optional DOMAIN_MIN/DOMAIN_MAX.
    public static func parseCube(_ text: String, space: ImportedTableSpace = .sRGB) throws -> Cube {
        var title: String?
        var size3D: Int?
        var size1D: Int?
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var rows: [SIMD3<Float>] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = parts.first else { continue }
            switch keyword.uppercased() {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                size3D = parts.count > 1 ? Int(parts[1]) : nil
            case "LUT_1D_SIZE":
                size1D = parts.count > 1 ? Int(parts[1]) : nil
            case "DOMAIN_MIN":
                domainMin = try vector(parts.dropFirst())
            case "DOMAIN_MAX":
                domainMax = try vector(parts.dropFirst())
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                if parts.count >= 3, let lo = Float(parts[1]), let hi = Float(parts[2]) {
                    domainMin = SIMD3(repeating: lo)
                    domainMax = SIMD3(repeating: hi)
                }
            default:
                guard keyword.first.map({ $0.isNumber || $0 == "-" || $0 == "." }) == true else { continue }
                try rows.append(vector(parts))
            }
        }
        guard domainMax.x > domainMin.x, domainMax.y > domainMin.y, domainMax.z > domainMin.z else {
            throw LookTableImportError.notACube("DOMAIN_MAX must exceed DOMAIN_MIN")
        }
        let span = domainMax - domainMin

        let sample: (SIMD3<Float>) -> SIMD3<Float>
        let nativeSize: Int
        if let size = size3D {
            guard LookTable.sizeRange.contains(size) else { throw LookTableImportError.unsupportedSize(size) }
            guard rows.count == size * size * size else {
                throw LookTableImportError.notACube("expected \(size * size * size) rows, found \(rows.count)")
            }
            let native = try LookTable(size: size, floats: rows.flatMap { [$0.x, $0.y, $0.z] })
            sample = { native.sample(($0 - domainMin) / span) }
            nativeSize = size
        } else if let size = size1D {
            guard size >= 2, size <= 65536, rows.count == size else {
                throw LookTableImportError.notACube("expected \(size) rows for the 1D table")
            }
            func curve(_ x: Float, _ channel: Int) -> Float {
                let p = min(max(x, 0), 1) * Float(size - 1)
                let i = min(Int(p), size - 2)
                let f = p - Float(i)
                return rows[i][channel] * (1 - f) + rows[i + 1][channel] * f
            }
            sample = { c in
                let x = simd_clamp((c - domainMin) / span, .zero, SIMD3(repeating: 1))
                return SIMD3(curve(x.x, 0), curve(x.y, 1), curve(x.z, 2))
            }
            nativeSize = storedSize
        } else {
            throw LookTableImportError.notACube("no LUT_3D_SIZE or LUT_1D_SIZE line")
        }
        let table = try adapt(sample, from: space, size: min(max(nativeSize, 17), storedSize))
        return Cube(title: title, table: table)
    }

    private static func vector(_ parts: some Collection<Substring>) throws -> SIMD3<Float> {
        let numbers = parts.prefix(3).compactMap { Float($0) }
        guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else {
            throw LookTableImportError.notACube("a row isn't three numbers")
        }
        return SIMD3(numbers[0], numbers[1], numbers[2])
    }

    /// Writes a table as `.cube` text, in Redlamp's own space.
    public static func cubeText(_ table: LookTable, title: String) -> String {
        var lines = [
            "TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"",
            "# Redlamp look table, space \(table.space.rawValue)",
            "LUT_3D_SIZE \(table.size)",
        ]
        for b in 0 ..< table.size {
            for g in 0 ..< table.size {
                for r in 0 ..< table.size {
                    let v = table.entry(r: r, g: g, b: b)
                    lines.append(String(format: "%.6f %.6f %.6f", v.x, v.y, v.z))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - HaldCLUT

    /// An identity HaldCLUT: a level³ × level³ image holding a level²-point table. Grade it
    /// in any editor (with color management off, or in sRGB) and import the result.
    public static func haldIdentity(level: Int = 8) -> CGImage? {
        let cube = level * level
        let side = level * level * level
        var pixels = [UInt16](repeating: 0, count: side * side * 4)
        for i in 0 ..< cube * cube * cube {
            let r = i % cube, g = (i / cube) % cube, b = i / (cube * cube)
            let o = i * 4
            pixels[o] = UInt16((Double(r) / Double(cube - 1) * 65535).rounded())
            pixels[o + 1] = UInt16((Double(g) / Double(cube - 1) * 65535).rounded())
            pixels[o + 2] = UInt16((Double(b) / Double(cube - 1) * 65535).rounded())
            pixels[o + 3] = 65535
        }
        return PixelImage.makeImage16(
            pixels,
            width: side,
            height: side,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB),
        )
    }

    /// Reads a graded HaldCLUT back as a look table.
    public static func parseHald(_ image: CGImage, space: ImportedTableSpace = .sRGB) throws -> LookTable {
        guard image.width == image.height else { throw LookTableImportError.notAHaldImage(
            width: image.width,
            height: image.height,
        ) }
        let side = image.width
        guard let level = (2 ... 16).first(where: { $0 * $0 * $0 == side }) else {
            throw LookTableImportError.notAHaldImage(width: image.width, height: image.height)
        }
        guard let pixels = PixelImage(image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw LookTableImportError.unreadableImage
        }
        let cube = level * level
        var floats = [Float]()
        floats.reserveCapacity(cube * cube * cube * 3)
        for i in 0 ..< cube * cube * cube {
            let c = pixels[i % side, i / side]
            floats.append(contentsOf: [c.x, c.y, c.z])
        }
        guard cube <= LookTable.sizeRange.upperBound else { throw LookTableImportError.unsupportedSize(cube) }
        let native = try LookTable(size: cube, floats: floats)
        return try adapt({ native.sample($0) }, from: space, size: min(cube, storedSize))
    }

    public static func readImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw LookTableImportError.unreadableImage }
        return image
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil,
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Wraps a table as a recipe with an embedded Base Look, ready to install.
    public static func recipe(for table: LookTable, name: String, id: String = RecipeNamespace.newLocalID()) -> Recipe {
        let look = BaseLookPackage(
            id: id + "/look", name: name, summary: "Imported look table", parameters: .identity, table: table,
        )
        return Recipe(
            id: id,
            name: name,
            group: "Imported",
            tags: ["lut"],
            includes: [.baseLook],
            settings: RecipeSettings(),
            baseLook: look.reference,
            embeddedBaseLooks: [look],
            created: Date(),
        )
    }
}
