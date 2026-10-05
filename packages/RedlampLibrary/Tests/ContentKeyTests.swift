import Foundation
import Testing
@testable import RedlampLibrary

/// A photo's content key follows its size and first 64 KiB, and nothing else.
struct ContentKeyTests {
    /// 128 KiB of 0, 1, …, 255, over and over.
    static let file = Data((0 ..< 128 * 1024).map { UInt8(truncatingIfNeeded: $0) })

    @Test func `the key is SHA-256's first 16 bytes over the size and the head`() {
        #expect(ContentKey(fileSize: 3, head: Data("abc".utf8)).hex == "ce91dc5eec0139adf091900d225971d6")
        #expect(ContentKey(fileSize: Self.file.count, head: Self.file).hex == "7067f12be482f73f2e6f70a39c0a6f83")
    }

    @Test func `the key is the same every time`() {
        #expect(ContentKey(fileSize: Self.file.count, head: Self.file) == ContentKey(
            fileSize: Self.file.count, head: Self.file,
        ))
    }

    @Test func `bytes after the first 64 KiB don't change the key`() {
        var changed = Self.file
        changed[ContentKey.headLength] ^= 0xFF
        changed[changed.count - 1] ^= 0xFF
        let key = ContentKey(fileSize: Self.file.count, head: Self.file)
        #expect(ContentKey(fileSize: Self.file.count, head: changed) == key)
        #expect(ContentKey(fileSize: Self.file.count, head: Self.file.prefix(ContentKey.headLength)) == key)
    }

    @Test func `the size and every byte of the first 64 KiB change the key`() {
        let key = ContentKey(fileSize: Self.file.count, head: Self.file)
        #expect(ContentKey(fileSize: Self.file.count + 1, head: Self.file) != key)
        for index in [0, 1000, ContentKey.headLength - 1] {
            var changed = Self.file
            changed[index] ^= 0x01
            #expect(ContentKey(fileSize: Self.file.count, head: changed) != key, "byte \(index)")
        }
    }

    @Test func `a key round-trips through its hex, its bytes and JSON`() throws {
        let key = ContentKey(fileSize: Self.file.count, head: Self.file)
        #expect(ContentKey(hex: key.hex) == key)
        #expect(ContentKey(hex: key.hex.uppercased()) == key)
        #expect(key.description == key.hex)
        #expect(key.data.count == 16)
        #expect(key.data.first == 0x70)
        #expect(ContentKey(data: key.data) == key)
        let json = try JSONEncoder().encode([key])
        #expect(String(bytes: json, encoding: .utf8) == #"["7067f12be482f73f2e6f70a39c0a6f83"]"#)
        #expect(try JSONDecoder().decode([ContentKey].self, from: json) == [key])
    }

    @Test func `text that isn't 32 hexadecimal digits isn't a key`() {
        for text in [
            "",
            "7067f12be482f73f2e6f70a39c0a6f8",
            "7067f12be482f73f2e6f70a39c0a6f83a",
            "+067f12be482f73f2e6f70a39c0a6f83",
            "7067f12be482f73f2e6f70a39c0a6g83",
        ] {
            #expect(ContentKey(hex: text) == nil, "\(text)")
        }
        #expect(ContentKey(data: Data(count: 15)) == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ContentKey].self, from: Data(#"["not a key"]"#.utf8))
        }
    }
}
