import CoreGraphics
import Foundation
import simd

/// A capture-chart layout: a colour lattice laid out to survive a phone app's resize, crop,
/// JPEG and spatial effects.
///
/// Each chart holds blue slices of the lattice as square blocks of patches (red along x,
/// green along y), so neighbouring patches differ by a single lattice step: JPEG chroma
/// blocks and resampling kernels then mix nearly identical colours. The blocks sit on a
/// neutral grey (sRGB 0.46) with two-patch grey gaps between them; that grey, sampled on a
/// sparse grid, measures the filter's spatial gain field and grain. Eight finder markers
/// (QR-style 1:1:3:1:1 squares in a white quiet ring) at the lattice's corners and edge
/// midpoints give the transform; the two layouts' markers form different rectangles, so one
/// can't be mistaken for the other. A barcode names the chart and the layout, and a grey
/// ramp under the lattice gives the neutral tone curve at every level.
public struct CaptureLayout: Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// Three 2048 px charts with a 25-point lattice, plus separate photos.
        case full
        /// One 3072 px image: a 21-point lattice, photo tiles and a resolution probe.
        case compact
    }

    /// A group of vertical black and white bars.
    public struct LinePairs: Sendable, Hashable {
        /// Chart pixels per black-white pair.
        public var period: Float
        public var rect: CGRect
    }

    public struct Patch: Sendable, Hashable {
        /// Lattice indices (red, green, blue), each 0..<lattice.
        public var node: SIMD3<Int>
        /// In chart pixels, y down.
        public var rect: CGRect

        public var centre: SIMD2<Float> {
            SIMD2(Float(rect.midX), Float(rect.midY))
        }
    }

    /// A point of the grey surround sampled for the gain field and grain.
    public struct Probe: Sendable, Hashable {
        public var centre: SIMD2<Float>
        /// Half the side of the sampled square, in chart pixels.
        public var radius: Float
        /// Far enough from everything else to measure grain in a larger window.
        public var open: Bool
    }

    public let kind: Kind
    public let side: Int
    public let lattice: Int
    public let patch: Int
    public let blocksPerRow: Int
    public let blockGap: Int
    public let latticeOrigin: SIMD2<Int>
    /// Block slots left grey, so the gain field has samples inside the lattice.
    public let emptySlots: Set<Int>
    public let chartCount: Int
    /// Marker module; a marker is 7 modules plus a 1-module white quiet ring.
    public let markerModule: Int
    /// Corners, then edge midpoints.
    public let markerCentres: [SIMD2<Float>]
    /// Each copy: black reference, white reference, four bits of the chart code (MSB first)
    /// and an odd-parity cell.
    public let barcodeCopies: [[CGRect]]
    public let rampRect: CGRect
    public let linePairs: [LinePairs]
    public let photoTiles: [CGRect]

    public var blockSide: Int {
        lattice * patch
    }

    public var latticeSide: Int {
        blocksPerRow * blockSide + (blocksPerRow - 1) * blockGap
    }

    public var latticeRect: CGRect {
        CGRect(x: latticeOrigin.x, y: latticeOrigin.y, width: latticeSide, height: latticeSide)
    }

    public var slotsPerChart: Int {
        blocksPerRow * blocksPerRow - emptySlots.count
    }

    var markerBox: Int {
        9 * markerModule
    }

    // MARK: - The layouts

    /// Three 2048 px charts. Everything a 4:5 crop of the square keeps (the central 80% of
    /// the width) holds all of the markers and the lattice.
    public static let full: CaptureLayout = {
        let side = 2048, patch = 18, lattice = 25, perRow = 3, gap = 36, module = 10, markerGap = 6
        let latticeSide = perRow * lattice * patch + (perRow - 1) * gap
        let origin = (side - latticeSide) / 2
        let low = Float(origin - markerGap - 9 * module / 2)
        let high = Float(origin + latticeSide + markerGap + 9 * module / 2)
        let mid = Float(side) / 2
        let cell = 30, pitch = 48, start = 330
        let copies = [false, true].map { right in
            (0 ..< 7).map { i -> CGRect in
                let left = start + i * pitch
                return CGRect(x: right ? side - left - cell : left, y: Int(low) - cell / 2, width: cell, height: cell)
            }
        }
        return CaptureLayout(
            kind: .full, side: side, lattice: lattice, patch: patch, blocksPerRow: perRow, blockGap: gap,
            latticeOrigin: SIMD2(origin, origin), emptySlots: [], chartCount: 3, markerModule: module,
            markerCentres: rectangle(x: [low, mid, high], y: [low, mid, high]),
            barcodeCopies: copies,
            rampRect: CGRect(x: origin, y: 1850, width: latticeSide, height: 70),
            linePairs: [], photoTiles: [],
        )
    }()

    /// One 3072 px square, for one pick, one apply and one export per filter.
    ///
    /// The lattice, markers, barcode, ramp and line pairs all sit in the central 80% of both
    /// axes, so a 4:5 or 5:4 crop keeps them; the photo tiles are in the top and bottom bands,
    /// inside the central 80% of the width. With 14 px patches the lattice keeps 9.3 px
    /// patches when an app scales the long edge to 2048 px, and 6.6 px at 1440 px.
    public static let compact: CaptureLayout = {
        let side = 3072, patch = 14, lattice = 21, perRow = 5, gap = 28, module = 12, markerGap = 8
        let latticeSide = perRow * lattice * patch + (perRow - 1) * gap
        let origin = SIMD2((side - latticeSide) / 2, 688)
        let half = 9 * module / 2
        let left = Float(origin.x - markerGap - half), right = Float(origin.x + latticeSide + markerGap + half)
        let top = Float(origin.y - markerGap - half), bottom: Float = 2446
        let ramp = CGRect(x: origin.x, y: 2300, width: latticeSide, height: 70)
        let cell = 36, pitch = 56, start = 923
        let copies = [top, bottom].map { y in
            (0 ..< 7).map { CGRect(x: start + $0 * pitch, y: Int(y) - cell / 2, width: cell, height: cell) }
        }
        let pairs = linePairPeriods.enumerated().map { i, period in
            LinePairs(period: period, rect: CGRect(x: 1610 + i * 58, y: Int(top) - 32, width: 48, height: 64))
        }
        let tileWidth = 585, tileHeight = 390, tileGap = 24
        let tileStart = (side - (4 * tileWidth + 3 * tileGap)) / 2
        let tiles = [142, 2540].flatMap { y in
            (0 ..< 4)
                .map { CGRect(x: tileStart + $0 * (tileWidth + tileGap), y: y, width: tileWidth, height: tileHeight) }
        }
        return CaptureLayout(
            kind: .compact, side: side, lattice: lattice, patch: patch, blocksPerRow: perRow, blockGap: gap,
            latticeOrigin: origin, emptySlots: [6, 8, 16, 18], chartCount: 1, markerModule: module,
            markerCentres: rectangle(x: [left, Float(side) / 2, right], y: [top, (top + bottom) / 2, bottom]),
            barcodeCopies: copies, rampRect: ramp, linePairs: pairs, photoTiles: tiles,
        )
    }()

    public static let all = [full, compact]

    /// Coarse to fine, so the resolved limit is where modulation first drops.
    static let linePairPeriods: [Float] = [24, 16, 12, 10, 8, 7, 6, 5, 4, 3.5, 3, 2.5]

    private static func rectangle(x: [Float], y: [Float]) -> [SIMD2<Float>] {
        [
            SIMD2(x[0], y[0]), SIMD2(x[1], y[0]), SIMD2(x[2], y[0]),
            SIMD2(x[0], y[1]), SIMD2(x[2], y[1]),
            SIMD2(x[0], y[2]), SIMD2(x[1], y[2]), SIMD2(x[2], y[2]),
        ]
    }

    // MARK: - Geometry

    public func slices(chart: Int) -> Range<Int> {
        let start = chart * slotsPerChart
        return start ..< min(start + slotsPerChart, lattice)
    }

    /// The block slots that hold slices, in order.
    var filledSlots: [Int] {
        (0 ..< blocksPerRow * blocksPerRow).filter { !emptySlots.contains($0) }
    }

    public func blockRect(slot: Int) -> CGRect {
        let column = slot % blocksPerRow, row = slot / blocksPerRow
        return CGRect(
            x: latticeOrigin.x + column * (blockSide + blockGap),
            y: latticeOrigin.y + row * (blockSide + blockGap),
            width: blockSide,
            height: blockSide,
        )
    }

    public func patches(chart: Int) -> [Patch] {
        var result: [Patch] = []
        for (slot, blue) in zip(filledSlots, slices(chart: chart)) {
            let block = blockRect(slot: slot)
            for green in 0 ..< lattice {
                for red in 0 ..< lattice {
                    let rect = CGRect(
                        x: block.minX + CGFloat(red * patch),
                        y: block.minY + CGFloat(green * patch),
                        width: CGFloat(patch),
                        height: CGFloat(patch),
                    )
                    result.append(Patch(node: SIMD3(red, green, blue), rect: rect))
                }
            }
        }
        return result
    }

    func markerRect(_ centre: SIMD2<Float>) -> CGRect {
        CGRect(
            x: CGFloat(centre.x) - CGFloat(markerBox) / 2,
            y: CGFloat(centre.y) - CGFloat(markerBox) / 2,
            width: CGFloat(markerBox),
            height: CGFloat(markerBox),
        )
    }

    /// The code a chart's barcode carries: 1–3 for the full charts, 9 for the compact image.
    public func barcodeNumber(chart: Int) -> Int {
        kind == .full ? chart + 1 : 9
    }

    /// Whether each barcode cell is black.
    public func barcode(chart: Int) -> [Bool] {
        let number = barcodeNumber(chart: chart)
        let bits = (0 ..< 4).map { number >> (3 - $0) & 1 == 1 }
        let parity = bits.count(where: { $0 }) % 2 == 0
        return [true, false] + bits + [parity]
    }

    /// The layout and chart a barcode names.
    public static func decodeBarcode(_ black: [Bool]) -> (layout: CaptureLayout, chart: Int)? {
        guard black.count == 7, black[0], !black[1] else { return nil }
        let bits = Array(black[2 ..< 6])
        guard (bits.count(where: { $0 }) + (black[6] ? 1 : 0)) % 2 == 1 else { return nil }
        let number = bits.reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
        if (1 ... full.chartCount).contains(number) {
            return (full, number - 1)
        }
        return number == 9 ? (compact, 0) : nil
    }

    /// Everything on the chart that isn't surround grey.
    func features(chart: Int) -> [CGRect] {
        filledSlots.prefix(slices(chart: chart).count).map(blockRect(slot:))
            + markerCentres.map(markerRect)
            + barcodeCopies.flatMap(\.self)
            + [rampRect] + linePairs.map(\.rect) + photoTiles
    }

    public func probes(chart: Int) -> [Probe] {
        let features = features(chart: chart)
        func clearance(_ p: SIMD2<Float>) -> Float {
            var nearest = min(p.x, p.y, Float(side) - p.x, Float(side) - p.y)
            for rect in features {
                let dx = max(Float(rect.minX) - p.x, 0, p.x - Float(rect.maxX))
                let dy = max(Float(rect.minY) - p.y, 0, p.y - Float(rect.maxY))
                nearest = min(nearest, (dx * dx + dy * dy).squareRoot())
            }
            return nearest
        }
        var probes: [Probe] = []
        for y in stride(from: 16, to: side, by: 32) {
            for x in stride(from: 16, to: side, by: 32) {
                let p = SIMD2(Float(x), Float(y))
                let clear = clearance(p)
                if clear >= 20 {
                    probes.append(Probe(centre: p, radius: 6, open: clear >= 32))
                }
            }
        }
        // The gaps between blocks reach into the middle of the lattice, where the surround
        // can't; a gap next to an empty block is already covered by the grid above.
        let origin = SIMD2<Float>(Float(latticeOrigin.x), Float(latticeOrigin.y))
        for gap in 1 ..< blocksPerRow {
            let offset = Float(gap * (blockSide + blockGap) - blockGap / 2)
            for t in stride(from: Float(patch / 2), to: Float(latticeSide), by: 24) {
                for p in [SIMD2(origin.x + offset, origin.y + t), SIMD2(origin.x + t, origin.y + offset)]
                    where clearance(p) >= Float(blockGap / 2 - 1) {
                    probes.append(Probe(centre: p, radius: 5, open: false))
                }
            }
        }
        return probes
    }

    /// The ramp's input level at chart x.
    public func rampLevel(x: Float) -> Float {
        let t = (x - Float(rampRect.minX)) / Float(rampRect.width)
        return CaptureChart.quantized(min(max(t, 0), 1))
    }

    public func nodeValue(_ node: SIMD3<Int>) -> SIMD3<Float> {
        let step = 1 / Float(lattice - 1)
        return SIMD3(
            CaptureChart.quantized(Float(node.x) * step),
            CaptureChart.quantized(Float(node.y) * step),
            CaptureChart.quantized(Float(node.z) * step),
        )
    }
}

/// The full kit's charts (`CaptureLayout.full`) and the helpers both layouts share.
public enum CaptureChart {
    public static let kitVersion = 1
    public static let surroundGrey: Float = 0.46

    public static var side: Int {
        CaptureLayout.full.side
    }

    public static var lattice: Int {
        CaptureLayout.full.lattice
    }

    public static var chartCount: Int {
        CaptureLayout.full.chartCount
    }

    public static func slices(chart: Int) -> Range<Int> {
        CaptureLayout.full.slices(chart: chart)
    }

    public static func pixels(chart: Int) -> PixelImage {
        CaptureLayout.full.pixels(chart: chart)
    }

    public static func nodeValue(_ node: SIMD3<Int>) -> SIMD3<Float> {
        CaptureLayout.full.nodeValue(node)
    }

    /// Values as an 8-bit file stores them, so the chart and its PNG agree exactly.
    public static func quantized(_ v: Float) -> Float {
        (min(max(v, 0), 1) * 255).rounded() / 255
    }

    /// An 8-bit sRGB image, the form phone apps read without surprises.
    public static func cgImage8(_ image: PixelImage) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for (i, p) in image.pixels.enumerated() {
            let c = simd_clamp(p, .zero, SIMD3(repeating: 1)) * 255
            bytes[i * 4] = UInt8(c.x.rounded())
            bytes[i * 4 + 1] = UInt8(c.y.rounded())
            bytes[i * 4 + 2] = UInt8(c.z.rounded())
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent,
        )
    }
}
