import CoreGraphics
import CoreText
import Foundation
import RedlampEngineAPI

/// Renders recipes through any `EditingEngine`: for the CLI, the MCP server, the Recipe Lab
/// and the golden-render tests, so every tool sees exactly what the app renders.
///
/// The engine has one current image, so every public operation runs exclusively: two
/// callers can never interleave an open of one photo with a render of another.
public final class RecipeRenderer: @unchecked Sendable {
    public let engine: any EditingEngine
    public let library: RecipeLibrary
    private let lock = AsyncLock()
    private var currentImage: URL?
    private var currentInfo: ImageInfo?
    private var autoWhiteBalance: [URL: WhiteBalanceValue] = [:]

    public init(engine: any EditingEngine, library: RecipeLibrary) {
        self.engine = engine
        self.library = library
        for definition in library.definitions() {
            engine.registerBaseLook(definition)
        }
    }

    private func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        await lock.lock()
        do {
            let result = try await body()
            await lock.unlock()
            return result
        } catch {
            await lock.unlock()
            throw error
        }
    }

    @discardableResult
    public func open(_ url: URL) async throws -> ImageInfo {
        try await exclusive { try await openUnlocked(url) }
    }

    @discardableResult
    private func openUnlocked(_ url: URL) async throws -> ImageInfo {
        if currentImage == url, let currentInfo {
            return currentInfo
        }
        let info = try await engine.open(url)
        currentImage = url
        currentInfo = info
        return info
    }

    /// Makes a recipe's embedded looks renderable.
    public func prepare(_ recipe: Recipe) {
        for package in recipe.embeddedBaseLooks {
            if let definition = try? package.definition() {
                engine.registerBaseLook(definition)
            }
        }
        if let look = recipe.baseLook, let definition = library.definition(for: look) {
            engine.registerBaseLook(definition)
        }
    }

    private func editUnlocked(for recipe: Recipe?, amount: Double) async -> EditRecipe {
        var start = EditRecipe()
        if let wb = currentInfo?.asShotWhiteBalance {
            start[.temperature] = wb.temperature
            start[.tint] = wb.tint
        }
        guard let recipe else { return start }
        prepare(recipe)
        var auto: WhiteBalanceValue?
        if recipe.includes.contains(.whiteBalance), recipe.settings.whiteBalanceMode == .auto, let url = currentImage {
            if let cached = autoWhiteBalance[url] {
                auto = cached
            } else {
                auto = await engine.autoWhiteBalance()
                autoWhiteBalance[url] = auto
            }
        }
        let asShot = currentInfo?.asShotWhiteBalance
        return recipe.apply(to: start, amount: amount) { mode in
            switch mode {
            case .asShot: asShot
            case .auto: auto
            case .custom: nil
            default: mode.presetValue
            }
        }
    }

    /// Renders a recipe (nil for the unedited photo) on an image.
    public func render(
        _ recipe: Recipe?,
        image: URL,
        maxLongEdge: Int? = 1024,
        amount: Double = 100,
        sixteenBit: Bool = false,
    ) async throws -> CGImage {
        try await exclusive { try await renderUnlocked(
            recipe,
            image: image,
            maxLongEdge: maxLongEdge,
            amount: amount,
            sixteenBit: sixteenBit,
        ) }
    }

    private func renderUnlocked(
        _ recipe: Recipe?,
        image: URL,
        maxLongEdge: Int?,
        amount: Double = 100,
        sixteenBit: Bool = false,
    ) async throws -> CGImage {
        try await openUnlocked(image)
        let edit = await editUnlocked(for: recipe, amount: amount)
        return try await stillUnlocked(edit, maxLongEdge: maxLongEdge, sixteenBit: sixteenBit)
    }

    /// Renders a finished edit on an image.
    public func render(
        edit: EditRecipe,
        image: URL,
        maxLongEdge: Int?,
        sixteenBit: Bool = false,
    ) async throws -> CGImage {
        try await exclusive {
            try await openUnlocked(image)
            return try await stillUnlocked(edit, maxLongEdge: maxLongEdge, sixteenBit: sixteenBit)
        }
    }

    private func stillUnlocked(_ edit: EditRecipe, maxLongEdge: Int?, sixteenBit: Bool) async throws -> CGImage {
        var request = StillRequest(recipe: edit, maxLongEdge: maxLongEdge)
        request.bitsPerComponent = sixteenBit ? 16 : 8
        return try await engine.renderStill(request)
    }

    // MARK: - Lint

    /// Renders the lint chart neutrally and with the recipe, and checks the difference.
    public func lint(_ recipe: Recipe) async throws -> [RecipeLint.Result] {
        let (baseline, render) = try await chartRenders(recipe)
        return RecipeLint.check(recipe: recipe, baseline: baseline, render: render)
    }

    public func chartRenders(_ recipe: Recipe) async throws -> (baseline: PixelImage, render: PixelImage) {
        let chart = try RecipeChart.fileURL()
        return try await exclusive {
            try await openUnlocked(chart)
            prepare(recipe)
            let baseline = try await stillUnlocked(EditRecipe(), maxLongEdge: nil, sixteenBit: true)
            let looked = try await stillUnlocked(RecipeLint.lintEdit(for: recipe), maxLongEdge: nil, sixteenBit: true)
            guard let a = PixelImage(baseline),
                  let b = PixelImage(looked) else { throw CocoaError(.fileReadCorruptFile) }
            return (a, b)
        }
    }

    // MARK: - Contact sheets

    /// A grid: one row per image, one column per recipe (nil for "Original").
    public func contactSheet(recipes: [Recipe?], images: [URL], tile: Int = 320) async throws -> CGImage {
        try await exclusive {
            let labelHeight = 22
            let gap = 6
            let tileHeight = tile * 2 / 3
            let width = gap + recipes.count * (tile + gap)
            let height = labelHeight + gap + images.count * (tileHeight + gap)
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ) else { throw CocoaError(.fileWriteUnknown) }
            context.setFillColor(CGColor(gray: 0.16, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (column, recipe) in recipes.enumerated() {
                let x = gap + column * (tile + gap)
                Self.draw(
                    text: recipe?.name ?? "Original",
                    in: context,
                    at: CGPoint(x: x + 2, y: height - labelHeight + 6),
                    width: CGFloat(tile),
                )
            }
            for (row, image) in images.enumerated() {
                let y = height - labelHeight - gap - (row + 1) * (tileHeight + gap) + gap
                for (column, recipe) in recipes.enumerated() {
                    let rendered = try await renderUnlocked(recipe, image: image, maxLongEdge: tile * 2)
                    let x = gap + column * (tile + gap)
                    let box = CGRect(x: x, y: y, width: tile, height: tileHeight)
                    context.saveGState()
                    context.clip(to: box)
                    context.interpolationQuality = .high
                    context.draw(
                        rendered,
                        in: Self.aspectFit(CGSize(width: rendered.width, height: rendered.height), in: box),
                    )
                    context.restoreGState()
                }
            }
            guard let sheet = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            return sheet
        }
    }

    /// Two renders side by side with their names, for pairwise comparison.
    public func compare(_ a: Recipe?, _ b: Recipe?, image: URL, tile: Int = 640) async throws -> CGImage {
        try await contactSheet(recipes: [a, b], images: [image], tile: tile)
    }

    static func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: box.midX - fitted.width / 2,
            y: box.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height,
        )
    }

    static func draw(text: String, in context: CGContext, at point: CGPoint, width: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.92, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let truncated = CTLineCreateTruncatedLine(
            line, Double(width), .end,
            CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes)),
        ) ?? line
        context.textPosition = point
        CTLineDraw(truncated, context)
    }
}

/// A FIFO async mutex (actors alone are reentrant across awaits).
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
