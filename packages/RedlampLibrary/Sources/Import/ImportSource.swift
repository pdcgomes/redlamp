import Foundation

/// What a volume's medium is, beyond `VolumeInfo`: whether it comes out of its drive or ejects, and
/// where the volume is mounted. The Mac says it for a real volume (`of(_:)`); a simulated card is
/// described as one.
public struct ImportMedium: Sendable, Hashable {
    /// Where the volume is mounted.
    public var root: URL
    /// The medium comes out of its drive: a card in a reader, or in a camera on USB.
    public var isRemovable: Bool
    /// The volume can be ejected: removable media, and drives attached from outside.
    public var isEjectable: Bool
    public var isInternal: Bool
    /// On a device attached to this Mac, not a network share.
    public var isLocal: Bool
    /// The Mac's startup volume.
    public var isRootFileSystem: Bool
    public var isReadOnly: Bool
    /// The file system as the Mac names it: "ExFAT", "MS-DOS (FAT32)", "APFS".
    public var format: String?

    public init(
        root: URL, isRemovable: Bool = false, isEjectable: Bool = false, isInternal: Bool = false,
        isLocal: Bool = true, isRootFileSystem: Bool = false, isReadOnly: Bool = false, format: String? = nil,
    ) {
        self.root = root
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.isRootFileSystem = isRootFileSystem
        self.isReadOnly = isReadOnly
        self.format = format
    }

    /// A card in a reader, mounted at `root`.
    public static func card(at root: URL, format: String = "ExFAT") -> ImportMedium {
        ImportMedium(root: root, isRemovable: true, isEjectable: true, format: format)
    }

    private static let keys: Set<URLResourceKey> = [
        .volumeURLKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsLocalKey,
        .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey,
    ]

    /// The medium of the volume `url` is on, as the Mac describes it; nil when it can't say.
    public static func of(_ url: URL) -> ImportMedium? {
        guard let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: keys),
              let root = values.volume
        else { return nil }
        return ImportMedium(
            root: root, isRemovable: values.volumeIsRemovable ?? false, isEjectable: values.volumeIsEjectable ?? false,
            isInternal: values.volumeIsInternal ?? false, isLocal: values.volumeIsLocal ?? false,
            isRootFileSystem: values.volumeIsRootFileSystem ?? false, isReadOnly: values.volumeIsReadOnly ?? false,
            format: values.volumeLocalizedFormatDescription,
        )
    }
}

/// Where photos are imported from (LIB-27): a card as a camera writes it, or any folder.
///
/// A card is the root of a volume on this Mac whose medium comes out or ejects (a card in a reader,
/// a camera on USB), holding a `DCIM` folder, where the DCF standard has cameras write their photos;
/// its photos are those below `DCIM`. Anything else is a folder, with the folders below it: the
/// Mac's own disks, network shares, a drive or a card without `DCIM`, a folder inside a card.
public struct ImportSource: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case card, folder
    }

    /// The index's name for the volume, and the source's path: one source per place.
    public let id: String
    public let url: URL
    public let kind: Kind
    /// The card's volume name, `EOS_DIGITAL`, or the folder's name.
    public let name: String
    public let volume: VolumeInfo
    public let medium: ImportMedium

    public init(url: URL, kind: Kind, name: String, volume: VolumeInfo, medium: ImportMedium) {
        let path = LibraryIndexer.path(url)
        self.url = URL(fileURLWithPath: path, isDirectory: true)
        self.kind = kind
        self.name = name
        self.volume = volume
        self.medium = medium
        id = VolumeIORegistry.key(for: volume, probe: self.url) + ":" + path
    }

    /// Where its photos are: `DCIM` on a card, the folder itself otherwise.
    public var photosFolder: URL {
        kind == .card ? url.appending(path: Self.cameraFolder, directoryHint: .isDirectory) : url
    }

    /// The folder DCF cameras write their photos in.
    public static let cameraFolder = "DCIM"

    /// The source at `url`, a card or a folder, as `fileSystem` lists it. `medium` describes its
    /// volume where the Mac can't (a simulated card); by default the Mac says.
    public static func at(
        _ url: URL, fileSystem: any LibraryFileSystem = LocalFileSystem(), medium: ImportMedium? = nil,
    ) throws -> ImportSource {
        let folder = URL(fileURLWithPath: LibraryIndexer.path(url), isDirectory: true)
        let entries = try fileSystem.contentsOfDirectory(at: folder)
        let volume = try fileSystem.volume(of: folder)
        let medium = medium ?? ImportMedium.of(folder) ?? ImportMedium(
            root: folder, isInternal: volume.isInternal, isLocal: volume.isLocal,
        )
        let kind: Kind = isCard(folder, medium: medium, entries: entries) ? .card : .folder
        let name = kind == .card ? volume.name ?? folder.lastPathComponent : folder.lastPathComponent
        return ImportSource(url: folder, kind: kind, name: name, volume: volume, medium: medium)
    }

    /// Whether the folder at `url`, listing `entries`, on a volume `medium` describes, is a card:
    /// its volume's root, on this Mac, not the startup volume, coming out or ejecting, with a `DCIM`
    /// folder.
    public static func isCard(_ url: URL, medium: ImportMedium, entries: [FileEntry]) -> Bool {
        guard LibraryIndexer.path(url) == LibraryIndexer.path(medium.root), medium.isLocal, !medium.isRootFileSystem,
              medium.isRemovable || medium.isEjectable
        else { return false }
        return entries.contains { $0.isDirectory && $0.name.uppercased() == cameraFolder }
    }

    /// The cards among the volumes mounted on this Mac, as a launch finds those already in.
    public static func mountedCards(fileSystem: any LibraryFileSystem = LocalFileSystem()) -> [ImportSource] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey],
            options: [.skipHiddenVolumes],
        ) ?? []
        return volumes.compactMap { volume in
            guard let source = try? at(volume, fileSystem: fileSystem), source.kind == .card else { return nil }
            return source
        }
    }
}

public extension VolumeProfile {
    /// A card in a USB card reader: about 90 MB a second, one request at a time, a little latency
    /// for each (an SD card at UHS-I's speed).
    static let cardReader = VolumeProfile(
        name: "card", latency: .microseconds(400), bandwidth: 90_000_000, maxInFlight: 1, isLocal: true,
        isInternal: false,
    )
}
