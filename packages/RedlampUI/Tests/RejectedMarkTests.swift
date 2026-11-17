import AppKit
import QuartzCore
import RedlampDocument
import Testing
@testable import RedlampUI

/// A pick's flag and a reject's X read on a light photo as on a dark one, in the filmstrip and the grid (#541): both
/// draw them on the grid's dark disc, and a rejected photo dims while its marks keep their strength.
@MainActor
struct RejectedMarkTests {
    /// A white photo, as one of a cloudy sky is, `height` pixels tall to 300 wide.
    private static func whitePhoto(height: Int = 200) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 300, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: height))
        return try #require(context.makeImage())
    }

    private static func item(_ flag: PhotoFlag?) -> RedlampUI.LibraryItem {
        RedlampUI.LibraryItem(url: URL(fileURLWithPath: "/Photos/IMG_1.JPG"), metadata: PhotoMetadata(flag: flag))
    }

    /// A cell drawn as on screen, over black, and read by the point from its top left corner.
    private struct Pixels {
        let scale: CGFloat
        let color: (Int, Int) -> (red: Double, green: Double, blue: Double)

        /// The lightest pixel within a point of `point`, from 0 for black to 1 for white.
        func lightness(near point: CGPoint) -> Double {
            let (x, y) = (Int(point.x * scale), Int(point.y * scale))
            let reach = Int(scale)
            return (y - reach ... y + reach).flatMap { y in
                (x - reach ... x + reach).map { x in
                    let pixel = color(x, y)
                    return 0.2126 * pixel.red + 0.7152 * pixel.green + 0.0722 * pixel.blue
                }
            }.max() ?? 0
        }

        /// The pixel at `point`.
        func lightness(at point: CGPoint) -> Double {
            let pixel = color(Int(point.x * scale), Int(point.y * scale))
            return 0.2126 * pixel.red + 0.7152 * pixel.green + 0.0722 * pixel.blue
        }
    }

    private func display(_ layer: CALayer) {
        layer.drawsAsynchronously = false
        layer.displayIfNeeded()
        layer.sublayers?.forEach(display)
    }

    /// A filmstrip cell showing `photo` flagged `flag`, in a window, as the strip shows it.
    private func filmstrip(_ flag: PhotoFlag?, _ photo: CGImage) throws -> Pixels {
        _ = NSApplication.shared
        let size = FilmstripCellView.size
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        let cell = FilmstripCellView(frame: container.bounds)
        container.addSubview(cell)
        window.contentView = container
        cell.configure(Self.item(flag), image: photo)
        cell.needsLayout = true
        container.layoutSubtreeIfNeeded()
        try display(#require(container.layer))
        let scale = window.backingScaleFactor
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0,
        ))
        rep.size = size
        container.cacheDisplay(in: container.bounds, to: rep)
        return Pixels(scale: scale) { x, y in
            let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .black
            return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
        }
    }

    /// A compact grid cell of `geometry` showing `photo` flagged `flag`, over black, at 2x.
    private func grid(_ flag: PhotoFlag?, _ photo: CGImage, _ geometry: GridCellGeometry) throws -> Pixels {
        let scale: CGFloat = 2
        let cell = LibraryGridCell()
        cell.place(CGRect(origin: .zero, size: geometry.cellSize), geometry: geometry, scale: scale)
        cell.configure(Self.item(flag), row: 0, image: photo, edge: photo.width)
        // Rendered inside another layer, so the cell's own opacity is drawn as the grid draws it.
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: geometry.cellSize)
        host.backgroundColor = CGColor(gray: 0, alpha: 1)
        host.addSublayer(cell.root)
        let (width, height) = (Int(geometry.cellSize.width * scale), Int(geometry.cellSize.height * scale))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        // The grid's layers lie top down: its first row in memory is the cell's top. The marks are symmetric top to
        // bottom, so drawn upside down they're where they are on screen.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        host.render(in: context)
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        let data = Array(UnsafeBufferPointer(start: pixels, count: width * height * 4))
        return Pixels(scale: scale) { x, y in
            let index = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return (Double(data[index]) / 255, Double(data[index + 1]) / 255, Double(data[index + 2]) / 255)
        }
    }

    @Test func `the filmstrip's reject X reads on a white photo, which dims while the X keeps its strength`() throws {
        let photo = try Self.whitePhoto()
        let (kept, picked, rejected) = try (filmstrip(nil, photo), filmstrip(.pick, photo), filmstrip(.reject, photo))
        // The mark's middle, and a spot on its disc below the X, inside the photo.
        let (mark, disc) = (CGPoint(x: 9, y: 9), CGPoint(x: 9, y: 15))
        let middle = CGPoint(x: FilmstripCellView.size.width / 2, y: FilmstripCellView.size.height / 2)

        #expect(rejected.lightness(near: mark) > 0.9, "the X is white, not dimmed with the photo")
        #expect(rejected.lightness(at: disc) < 0.4, "on a dark disc: \(rejected.lightness(at: disc))")
        #expect(picked.lightness(near: mark) > 0.9 && picked.lightness(at: disc) < 0.4, "a pick's flag on it too")
        #expect(kept.lightness(at: disc) > 0.9, "a photo with no flag has no disc")
        #expect(
            rejected.lightness(at: middle) < kept.lightness(at: middle) - 0.02,
            "the rejected photo dims: \(rejected.lightness(at: middle)) against \(kept.lightness(at: middle))",
        )
    }

    @Test func `the grid's reject X keeps its strength on a white photo, which dims`() throws {
        // Square, so the flag's corner is over the photo rather than the tile beside it.
        let photo = try Self.whitePhoto(height: 300)
        let geometry = GridCellGeometry(size: CGFloat(GridSize.standard), style: .compact)
        let (kept, picked, rejected) = try (
            grid(nil, photo, geometry), grid(.pick, photo, geometry), grid(.reject, photo, geometry),
        )
        let (mark, disc) = (geometry.flag, CGPoint(x: geometry.flag.x, y: geometry.flag.y + 6))
        let middle = CGPoint(x: geometry.image.midX, y: geometry.image.midY)

        #expect(rejected.lightness(near: mark) > 0.9, "the X is white, not dimmed with the photo")
        #expect(rejected.lightness(at: disc) < 0.4, "on a dark disc: \(rejected.lightness(at: disc))")
        #expect(picked.lightness(near: mark) > 0.9 && picked.lightness(at: disc) < 0.4, "a pick's flag on it too")
        #expect(kept.lightness(at: disc) > 0.9, "a photo with no flag has no disc")
        #expect(
            rejected.lightness(at: middle) < kept.lightness(at: middle) - 0.02,
            "the rejected photo dims: \(rejected.lightness(at: middle)) against \(kept.lightness(at: middle))",
        )
    }
}
