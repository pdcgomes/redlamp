import AppKit
import RedlampRecipes

/// Film looks' icons as images for menus and cards, drawn once per size.
@MainActor
enum FilmIconImage {
    private static var cache: [String: NSImage] = [:]

    /// The icon of the catalogue look a bundled Base Look or recipe ID belongs to.
    static func image(for id: String, points: CGFloat) -> NSImage? {
        guard let look = FilmLookCatalog.look(forBundledID: id) else { return nil }
        return image(for: look, points: points)
    }

    static func image(for look: FilmLookDefinition, points: CGFloat) -> NSImage? {
        let key = "\(look.id)@\(points)"
        if let cached = cache[key] {
            return cached
        }
        guard let drawn = look.icon.image(pixels: Int(points * 2)) else { return nil }
        let image = NSImage(cgImage: drawn, size: NSSize(width: points, height: points))
        cache[key] = image
        return image
    }
}
