import Foundation

/// A photo's alias in a report, and its file name.
public struct PhotoName: Codable, Sendable, Hashable {
    public var alias: String
    public var fileName: String
}

/// Takes out of a report's text what could say who someone is or where their files are: the
/// home folder, folders, and (unless they ask to include them) file names, which become the
/// photos' aliases. Reports are public, so everything they hold goes through `redact`.
public struct FeedbackRedactor: Sendable {
    public var home: String
    /// Folders the app knows about (the open folder, the working set), longest first.
    public var folders: [String]
    public var photos: [PhotoName]
    public var keepsFileNames: Bool

    public init(
        home: String = NSHomeDirectory(), folders: [String] = [], photos: [PhotoName] = [],
        keepsFileNames: Bool = false,
    ) {
        self.home = home
        self.folders = folders.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        self.photos = photos
        self.keepsFileNames = keepsFileNames
    }

    /// Absolute paths (and ones under `~`), up to the first space or quote: what's left of a path
    /// with spaces after the known folders and the home folder are taken out.
    private static var path: Regex<Substring> {
        /~?(?:\/[^\s"'“”‘’<>|()\[\],;:]+){2,}/
    }

    public func redact(_ text: String) -> String {
        var text = text
        for folder in folders {
            text = text.replacingOccurrences(of: folder + "/", with: "…/")
            text = text.replacingOccurrences(of: folder, with: "a folder")
        }
        if home.count > 1 {
            text = text.replacingOccurrences(of: home, with: "~")
        }
        let original = text
        text = original.replacing(Self.path) { match in
            // Part of a URL ("https://…") or of words ("ProRAW/HEIC/TIFF"), not a path.
            if match.range.lowerBound > original.startIndex {
                let previous = original[original.index(before: match.range.lowerBound)]
                if previous == ":" || previous == "/" || previous.isLetter || previous.isNumber {
                    return String(match.output)
                }
            }
            let components = match.output.split(separator: "/")
            return "…/" + (components.last.map(String.init) ?? "")
        }
        if !keepsFileNames {
            for (name, alias) in fileNameReplacements() {
                text = text.replacingOccurrences(of: name, with: alias)
            }
        }
        return text
    }

    /// Each photo's file name, and its name without the extension, longest first.
    private func fileNameReplacements() -> [(String, String)] {
        photos.flatMap { photo -> [(String, String)] in
            let stem = (photo.fileName as NSString).deletingPathExtension
            return stem.count >= 3 && stem != photo.fileName
                ? [(photo.fileName, photo.alias), (stem, photo.alias)] : [(photo.fileName, photo.alias)]
        }
        .sorted { $0.0.count > $1.0.count }
    }
}
