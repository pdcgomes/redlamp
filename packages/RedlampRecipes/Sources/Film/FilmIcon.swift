import CoreGraphics
import CoreText
import Foundation

/// A film look's small icon: a 35 mm canister, slide mount, cinema reel or paper print in the
/// stock's familiar colours, with its speed. Redlamp's own drawing, not the makers' packaging.
public struct FilmIcon: Sendable, Hashable {
    public enum Shape: String, Sendable, Hashable {
        case canister, slide, reel, paper
    }

    public struct Colour: Sendable, Hashable {
        public var r: Double, g: Double, b: Double

        public init(_ r: Double, _ g: Double, _ b: Double) {
            (self.r, self.g, self.b) = (r, g, b)
        }

        var cg: CGColor {
            CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }

    public var shape: Shape
    /// The canister, mount, reel or paper.
    public var body: Colour
    /// The label band, the slide's window, the reel's label or the print's image.
    public var band: Colour
    public var text: Colour
    /// The speed or short mark printed on the band, such as "400" or "800T".
    public var label: String
    /// The film leader's colour (orange-brown for colour negatives, grey for black and white).
    public var leader: Colour

    public init(_ shape: Shape, body: Colour, band: Colour, text: Colour, label: String, leader: Colour? = nil) {
        self.shape = shape
        self.body = body
        self.band = band
        self.text = text
        self.label = label
        self.leader = leader ?? Colour(0.55, 0.33, 0.16)
    }

    /// The icon at `pixels` square, transparent around the shape.
    public func image(pixels: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        context.scaleBy(x: CGFloat(pixels) / 64, y: CGFloat(pixels) / 64)
        context.setShouldAntialias(true)
        switch shape {
        case .canister: drawCanister(context)
        case .slide: drawSlide(context)
        case .reel: drawReel(context)
        case .paper: drawPaper(context)
        }
        return context.makeImage()
    }

    // MARK: - Shapes (a 64-unit square, y up)

    private static let metal = Colour(0.62, 0.64, 0.67)
    private static let metalDark = Colour(0.36, 0.38, 0.41)

    private func drawCanister(_ c: CGContext) {
        // The leader, out of the slot on the right, with sprocket holes along both edges.
        let leaderPath = CGMutablePath()
        leaderPath.move(to: CGPoint(x: 38, y: 19))
        leaderPath.addLine(to: CGPoint(x: 60, y: 19))
        leaderPath.addLine(to: CGPoint(x: 60, y: 37))
        leaderPath.addQuadCurve(to: CGPoint(x: 50, y: 43), control: CGPoint(x: 58, y: 43))
        leaderPath.addLine(to: CGPoint(x: 38, y: 43))
        leaderPath.closeSubpath()
        c.addPath(leaderPath)
        c.setFillColor(leader.cg)
        c.fillPath()
        c.setFillColor(CGColor(gray: 0, alpha: 0.45))
        for x in stride(from: 47.0, through: 57, by: 5) {
            c.fill(CGRect(x: x, y: 20.5, width: 2.4, height: 2.6))
            if x < 54 {
                c.fill(CGRect(x: x, y: 38.8, width: 2.4, height: 2.6))
            }
        }
        // The body, its label band and a highlight down the left, so it reads as a cylinder.
        fillRounded(c, CGRect(x: 8, y: 9, width: 34, height: 46), radius: 3, body)
        fillRounded(c, CGRect(x: 8, y: 21, width: 34, height: 22), radius: 0, band)
        c.setFillColor(CGColor(gray: 1, alpha: 0.22))
        c.fill(CGRect(x: 11, y: 9, width: 4, height: 46))
        c.setFillColor(CGColor(gray: 0, alpha: 0.16))
        c.fill(CGRect(x: 36, y: 9, width: 6, height: 46))
        // The caps and the spool's knob.
        fillRounded(c, CGRect(x: 6, y: 53, width: 38, height: 6), radius: 2, Self.metal)
        fillRounded(c, CGRect(x: 6, y: 5, width: 38, height: 6), radius: 2, Self.metal)
        fillRounded(c, CGRect(x: 19, y: 59, width: 12, height: 3.5), radius: 1.2, Self.metalDark)
        c.setFillColor(CGColor(gray: 0, alpha: 0.18))
        c.fill(CGRect(x: 6, y: 53, width: 38, height: 1.2))
        c.fill(CGRect(x: 6, y: 9.8, width: 38, height: 1.2))
        drawLabel(c, in: CGRect(x: 8, y: 21, width: 34, height: 22))
    }

    private func drawSlide(_ c: CGContext) {
        let mount = CGRect(x: 6, y: 6, width: 52, height: 52)
        fillRounded(c, mount, radius: 6, body)
        c.setStrokeColor(CGColor(gray: 0, alpha: 0.25))
        c.setLineWidth(1)
        c.addPath(CGPath(roundedRect: mount.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil))
        c.strokePath()
        // The transparency in its window: the band colour, lighter towards the top like a sky.
        let window = CGRect(x: 15, y: 22, width: 34, height: 26)
        c.saveGState()
        c.addPath(CGPath(roundedRect: window, cornerWidth: 2, cornerHeight: 2, transform: nil))
        c.clip()
        let top = Colour(min(band.r + 0.35, 1), min(band.g + 0.35, 1), min(band.b + 0.35, 1))
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [band.cg, top.cg] as CFArray, locations: [0, 1],
        ) {
            c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: window.minY), end: CGPoint(x: 0, y: window.maxY), options: [])
        }
        c.restoreGState()
        drawLabel(c, in: CGRect(x: 10, y: 8, width: 44, height: 13), colour: text)
    }

    private func drawReel(_ c: CGContext) {
        let centre = CGPoint(x: 32, y: 32)
        c.setFillColor(body.cg)
        c.fillEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
        c.setStrokeColor(Self.metal.cg)
        c.setLineWidth(2)
        c.strokeEllipse(in: CGRect(x: 5, y: 5, width: 54, height: 54))
        // Three windows in the flange, showing the wound film.
        for i in 0 ..< 3 {
            let angle = Double(i) * 2 * .pi / 3 + .pi / 2
            let point = CGPoint(x: centre.x + 17 * cos(angle), y: centre.y + 17 * sin(angle))
            c.setFillColor(leader.cg)
            c.fillEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
        }
        c.setFillColor(Self.metal.cg)
        c.fillEllipse(in: CGRect(x: centre.x - 6, y: centre.y - 6, width: 12, height: 12))
        c.setFillColor(Self.metalDark.cg)
        c.fillEllipse(in: CGRect(x: centre.x - 2.5, y: centre.y - 2.5, width: 5, height: 5))
        let label = CGRect(x: 10, y: 3, width: 44, height: 15)
        fillRounded(c, label, radius: 3, band)
        drawLabel(c, in: label)
    }

    private func drawPaper(_ c: CGContext) {
        c.saveGState()
        c.translateBy(x: 32, y: 32)
        c.rotate(by: -0.12)
        c.translateBy(x: -32, y: -32)
        c.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
        fillRounded(c, CGRect(x: 9, y: 6, width: 46, height: 54), radius: 1.5, body)
        c.restoreGState()
        c.saveGState()
        c.translateBy(x: 32, y: 32)
        c.rotate(by: -0.12)
        c.translateBy(x: -32, y: -32)
        // The print's image: a black and white gradient, darkest at the foot.
        let image = CGRect(x: 14, y: 20, width: 36, height: 35)
        c.addRect(image)
        c.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [CGColor(gray: 0.08, alpha: 1), CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0.9, alpha: 1)] as CFArray,
            locations: [0, 0.55, 1],
        ) {
            c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: image.minY), end: CGPoint(x: 0, y: image.maxY), options: [])
        }
        c.restoreGState()
        c.saveGState()
        c.translateBy(x: 32, y: 32)
        c.rotate(by: -0.12)
        c.translateBy(x: -32, y: -32)
        drawLabel(c, in: CGRect(x: 12, y: 7, width: 40, height: 12), colour: text)
        c.restoreGState()
    }

    // MARK: - Drawing helpers

    private func fillRounded(_ c: CGContext, _ rect: CGRect, radius: CGFloat, _ colour: Colour) {
        c.setFillColor(colour.cg)
        if radius > 0 {
            c.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            c.fillPath()
        } else {
            c.fill(rect)
        }
    }

    /// The label centred in `rect`, as large as fits.
    private func drawLabel(_ c: CGContext, in rect: CGRect, colour: Colour? = nil) {
        var size = rect.height * 0.78
        var line: CTLine
        var bounds: CGRect
        repeat {
            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
                ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): (colour ?? text).cg,
            ]
            line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            size -= 0.5
        } while bounds.width > rect.width - 4 && size > 4
        c.textPosition = CGPoint(
            x: rect.midX - bounds.width / 2 - bounds.minX,
            y: rect.midY - bounds.height / 2 - bounds.minY,
        )
        CTLineDraw(line, c)
    }
}
