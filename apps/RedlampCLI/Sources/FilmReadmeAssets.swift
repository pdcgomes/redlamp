import CoreGraphics
import CoreText
import Foundation
import RedlampRecipes

/// `redlamp recipe film --readme`: the README's film-look images in `docs/images/film/`: each
/// look's icon, an example of each look (the original above the look, on the same photos) and
/// an overview of every look on one photo. The photos are CC0 look-development files.
enum FilmReadmeAssets {
    /// A landscape, flowers and a night street from the look-development set.
    static let examplePhotos = ["Sony_ILCE-6700.ARW", "Pentax_KF.PEF", "Canon_EOS-Kiss-F.CR2"]
    static let overviewPhoto = "Sony_ILCE-6700.ARW"
    static let tile = CGSize(width: 420, height: 280)
    static let gap: CGFloat = 6

    static func write(recipes: [(FilmLookDefinition, Recipe)], renderer: RecipeRenderer, into folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photos = examplePhotos.map { Repository.root.appendingPathComponent("build/look-dev/\($0)") }
        guard photos.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CLIError(description: "the look-development set isn't downloaded (mise run lookdev)")
        }
        var originals: [CGImage] = []
        for photo in photos {
            try await originals.append(renderer.render(nil, image: photo, maxLongEdge: 1200))
        }
        for (look, recipe) in recipes {
            if let icon = look.icon.image(pixels: 128) {
                try ImageFile.write(icon, to: folder.appendingPathComponent("icon-\(look.id).png"))
            }
            var rendered: [CGImage] = []
            for photo in photos {
                try await rendered.append(renderer.render(recipe, image: photo, maxLongEdge: 1200))
            }
            let sheet = try grid(rows: [originals, rendered])
            try ImageFile.write(sheet, to: folder.appendingPathComponent("look-\(look.id).jpg"))
            print("\(look.id): icon and example")
        }

        let photo = Repository.root.appendingPathComponent("build/look-dev/\(overviewPhoto)")
        var cells: [(CGImage, String, FilmIcon?)] = try await [(renderer.render(nil, image: photo, maxLongEdge: 900), "Original", nil)]
        for (look, recipe) in recipes {
            try await cells.append((renderer.render(recipe, image: photo, maxLongEdge: 900), look.name, look.icon))
        }
        try ImageFile.write(overview(cells, columns: 4), to: folder.appendingPathComponent("overview.jpg"))
        print("wrote \(folder.path)")
    }

    /// Images cropped to the tile's 3:2 and laid out in rows.
    private static func grid(rows: [[CGImage]]) throws -> CGImage {
        let columns = rows.map(\.count).max() ?? 0
        let size = CGSize(
            width: CGFloat(columns) * tile.width + CGFloat(columns - 1) * gap,
            height: CGFloat(rows.count) * tile.height + CGFloat(rows.count - 1) * gap,
        )
        let context = try canvas(size)
        for (r, row) in rows.enumerated() {
            for (c, image) in row.enumerated() {
                let origin = CGPoint(
                    x: CGFloat(c) * (tile.width + gap),
                    y: size.height - CGFloat(r + 1) * tile.height - CGFloat(r) * gap,
                )
                draw(image, in: CGRect(origin: origin, size: tile), context)
            }
        }
        guard let image = context.makeImage() else { throw CLIError(description: "couldn't draw the grid") }
        return image
    }

    /// Every look on one photo, each with its icon and name underneath.
    private static func overview(_ cells: [(CGImage, String, FilmIcon?)], columns: Int) throws -> CGImage {
        let caption: CGFloat = 40
        let rows = (cells.count + columns - 1) / columns
        let cell = CGSize(width: tile.width, height: tile.height + caption)
        let size = CGSize(
            width: CGFloat(columns) * cell.width + CGFloat(columns - 1) * gap,
            height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap,
        )
        let context = try canvas(size)
        for (index, (image, name, icon)) in cells.enumerated() {
            let c = index % columns, r = index / columns
            let origin = CGPoint(
                x: CGFloat(c) * (cell.width + gap),
                y: size.height - CGFloat(r + 1) * cell.height - CGFloat(r) * gap,
            )
            draw(image, in: CGRect(x: origin.x, y: origin.y + caption, width: tile.width, height: tile.height), context)
            var textX = origin.x + 8
            if let icon, let glyph = icon.image(pixels: 64) {
                context.draw(glyph, in: CGRect(x: origin.x + 6, y: origin.y + 4, width: 32, height: 32))
                textX += 34
            }
            text(name, at: CGPoint(x: textX, y: origin.y + 13), size: 17, context)
        }
        guard let image = context.makeImage() else { throw CLIError(description: "couldn't draw the overview") }
        return image
    }

    private static func canvas(_ size: CGSize) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { throw CLIError(description: "couldn't make a canvas") }
        context.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        return context
    }

    /// Centre-cropped to fill `rect`.
    private static func draw(_ image: CGImage, in rect: CGRect, _ context: CGContext) {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.saveGState()
        context.clip(to: rect)
        context.draw(image, in: CGRect(
            x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height,
        ))
        context.restoreGState()
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, _ context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.92, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
