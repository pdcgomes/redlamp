import Foundation

/// A folder's listing as one number: its entry count and a hash of each entry's name, size and
/// modification date, whatever order the listing gives them in. A folder whose signature is the one
/// its photos were indexed at (`FolderRecord.indexedSignature`) needs nothing read again.
///
/// Subfolders count by name alone: a folder's date changes with what's in it, which its own
/// signature covers, so a change deep in a tree doesn't change every folder above it. Sidecar
/// packages count with their dates, which change whenever their `edit.json` is replaced.
public struct FolderSignature: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init(_ entries: some Sequence<FileEntry>) {
        var count: UInt64 = 0
        var sum: UInt64 = 0
        for entry in entries {
            count += 1
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in entry.name.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
            if FolderWalk.isFolder(entry) {
                hash = Self.mix(hash ^ 1)
            } else {
                hash = Self.mix(hash ^ (entry.isDirectory ? 2 : 3))
                hash = Self.mix(hash &+ UInt64(bitPattern: entry.size))
                hash = Self.mix(hash &+ entry.modified.timeIntervalSinceReferenceDate.bitPattern)
            }
            sum &+= hash
        }
        rawValue = Int64(bitPattern: Self.mix(sum ^ Self.mix(count &+ 0x9E37_79B9_7F4A_7C15)))
    }

    public var description: String {
        String(UInt64(bitPattern: rawValue), radix: 16)
    }

    /// SplitMix64's finaliser: every bit of the input reaches every bit of the output.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
