/// RGB triples without `SIMD3<Float>`'s padding to 16 bytes.
struct PackedRGB: RandomAccessCollection, Sendable {
    private let values: [Float]

    init(_ colours: some Collection<SIMD3<Float>>) {
        var values: [Float] = []
        values.reserveCapacity(colours.count * 3)
        for colour in colours {
            values.append(colour.x)
            values.append(colour.y)
            values.append(colour.z)
        }
        self.values = values
    }

    var startIndex: Int {
        0
    }

    var endIndex: Int {
        values.count / 3
    }

    subscript(index: Int) -> SIMD3<Float> {
        SIMD3(values[index * 3], values[index * 3 + 1], values[index * 3 + 2])
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try values.withUnsafeBytes(body)
    }
}
