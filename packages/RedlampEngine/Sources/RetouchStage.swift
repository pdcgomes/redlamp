import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampMasking
import RedlampServices
import simd

/// Remove, Heal and Clone spots baked into a copy of the session's pyramid (see `Retouch.metal`).
/// The copy stands in for the photo everywhere after it: Detail, the develop kernel and its masks.
///
/// Its state is behind `lock`: the engine renders on one queue, and its maps' refresh works on
/// others.
final class RetouchStage: @unchecked Sendable {
    /// Points on a circle's rim for Heal.
    static let rimSamples = 256
    /// The most points on a brushed spot's outline, and on its stroke.
    static let maximumOutline = 1024
    static let maximumStroke = 512
    /// A photo's recipe and the one it's compared with.
    private static let maximumEntries = 2

    /// Where a spot lands in the pyramid, in level-0 texels.
    struct Placement: Equatable {
        /// The stroke, the spot's own point first; one point for a circle.
        var points: [SIMD2<Float>]
        /// From the spot to its source.
        var offset: SIMD2<Float>
        var radius: Float
        var origin: SIMD2<Int>
        var size: SIMD2<Int>
        /// A picked person or object's shape over the box, for a region spot.
        var region: Region?

        var center: SIMD2<Float> {
            points[0]
        }

        /// How much the spot covers `point` (level-0 texels): the region's alpha, or for a circle or
        /// stroke, 1 within `reach` of it.
        func covers(_ point: SIMD2<Float>, reach: Float) -> Bool {
            guard let region else { return RetouchStage.strokeDistance(point, points) < reach }
            return region.alpha(at: point - SIMD2(Float(origin.x), Float(origin.y))) > 0.001
        }

        var source: SIMD2<Float> {
            points[0] + offset
        }
    }

    /// A region spot's shape over its placement's box: its alpha (1 inside the region grown by the
    /// spot's radius less its feather, fading to 0 at the full radius), at `scale` level-0 texels per
    /// texel, and points on the edge where it reaches 0.
    struct Region: Equatable {
        var width: Int
        var height: Int
        var scale: Float
        var alphas: [Float]
        var rim: [SIMD2<Float>]
        var spacing: Float

        /// Bilinear, at `point` in level-0 texels from the box's origin.
        func alpha(at point: SIMD2<Float>) -> Float {
            let p = point / scale - 0.5
            let x0 = Int(floor(p.x)), y0 = Int(floor(p.y))
            let t = p - SIMD2(Float(x0), Float(y0))
            func at(_ x: Int, _ y: Int) -> Float {
                alphas[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
            }
            let top = at(x0, y0) * (1 - t.x) + at(x0 + 1, y0) * t.x
            let bottom = at(x0, y0 + 1) * (1 - t.x) + at(x0 + 1, y0 + 1) * t.x
            return top * (1 - t.y) + bottom * t.y
        }
    }

    private struct RegionKey: Hashable {
        var spot: RetouchSpot
        var orientation: Int
        var width: Int
        var height: Int
    }

    private struct Entry {
        var original: ImageSession
        var spots: [RetouchSpot]
        var fills: FillVersion
        /// With the photo's maps.
        var retouched: ImageSession
        /// Until its own are made, with the maps of the photo's latest retouch that has them, or
        /// the photo's.
        var interim: ImageSession
        /// With maps made from its own pyramid (see `Maps`), once they are.
        var refreshed: ImageSession?
        /// The command buffer putting the spots in, until it's known to be done.
        var baking: (any MTLCommandBuffer)?
    }

    /// How a retouched photo's maps (`SessionBuilder.maps`: Highlights and Shadows', Clarity's,
    /// Dehaze's and glow's) are brought up to date, from process 10. Until they're made again from
    /// the retouched pyramid, what the spots replaced lives on in them, and a removed object's
    /// shape shows wherever those adjustments are used.
    enum Maps {
        /// The photo's: an edit from before process 10.
        case current
        /// The latest made, then its own made in the background once the spots are in, and the
        /// photo rendered again (`onRefresh`): an interactive frame.
        case refreshLater
        /// Its own, made before it renders: a still, which comes out the same every time.
        case fresh
    }

    /// Called, from any thread, once a retouched photo's maps were made again in the background, to
    /// render the latest frame with them. Set before the stage is used.
    var onRefresh: (@Sendable () -> Void)?

    /// A Remove spot's fill: where each texel of a region at the working level copies from.
    struct FillMap {
        var level: Int
        /// The region, in the working level's texels.
        var origin: SIMD2<Int>
        var size: SIMD2<Int>
        /// Per texel of the region, the move to copy from, in level-0 texels.
        var offsets: [SIMD2<Float>]
        /// Keeps the session alive so its identifier can't be reused while cached.
        var owner: ImageSession
    }

    /// How Remove spots are filled. From process 12 (`second`), a fill copies from none of the
    /// edit's other Remove spots and none of the spots after it, and isn't matched on what those
    /// after it replace.
    enum FillVersion: Hashable {
        case first, second
    }

    /// A Remove spot and the spots before it, which its fill depends on, and from the second
    /// version, those after it that reach into its window.
    private struct FillKey: Hashable {
        var session: ObjectIdentifier
        var spots: [RetouchSpot]
        var later: [RetouchSpot]
        var version: FillVersion
    }

    /// Where a Remove spot's fill works: the pyramid level where its hole is at most
    /// `fillExtent` texels across, and the photo up to twice the hole's size around it, in that
    /// level's texels.
    struct FillWindow {
        var level: Int
        var low: SIMD2<Int>
        var high: SIMD2<Int>

        var scale: Float {
            Float(1 << level)
        }

        init?(_ placement: Placement, levels: Int, width: Int, height: Int) {
            let extent = Double(max(placement.size.x, placement.size.y))
            level = min(max(Int(ceil(log2(extent / RetouchStage.fillExtent))), 0), levels - 1)
            let scale = Float(1 << level)
            let levelWidth = max(1, width >> level), levelHeight = max(1, height >> level)
            let low = SIMD2(Float(placement.origin.x), Float(placement.origin.y)) / scale
            let high = SIMD2(
                Float(placement.origin.x + placement.size.x),
                Float(placement.origin.y + placement.size.y),
            ) / scale
            let margin = max(Int(ceil(simd_reduce_max(high - low) * 2)), 24)
            self.low = SIMD2(max(Int(floor(low.x)) - margin, 0), max(Int(floor(low.y)) - margin, 0))
            self.high = SIMD2(
                min(Int(ceil(high.x)) + margin, levelWidth),
                min(Int(ceil(high.y)) + margin, levelHeight),
            )
            guard self.high.x > self.low.x, self.high.y > self.low.y else { return nil }
        }

        /// Whether `placement`'s box overlaps the window.
        func reaches(_ placement: Placement) -> Bool {
            let shift = level
            let low = SIMD2(placement.origin.x >> shift, placement.origin.y >> shift)
            let high = SIMD2(
                (placement.origin.x + placement.size.x + (1 << shift) - 1) >> shift,
                (placement.origin.y + placement.size.y + (1 << shift) - 1) >> shift,
            )
            return low.x < self.high.x && high.x > self.low.x && low.y < self.high.y && high.y > self.low.y
        }
    }

    /// A photo's fills are kept across rebuilds, so moving another spot doesn't fill this one again.
    private static let maximumFills = 32
    /// The working level makes a hole at most this many texels across. REDLAMP_FILL_EXTENT
    /// overrides it, to tune.
    static let fillExtent = Double(ProcessInfo.processInfo.environment["REDLAMP_FILL_EXTENT"] ?? "") ?? 96

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let kernels: KernelLibrary
    private let lock = NSLock()
    /// Pyramids whose maps are being made in the background, not to be reused until they're done.
    private var refreshing: Set<ObjectIdentifier> = []
    private var entries: [Entry] = []
    private var fills: [FillKey: FillMap] = [:]
    private var fillOrder: [FillKey] = []
    private var regions: [RegionKey: Placement] = [:]
    /// Generative fills' bitmaps on the GPU, by hash, the most recent last.
    private var storedFills: [String: any MTLTexture] = [:]
    private var storedOrder: [String] = []
    private lazy var filler = ContentAwareFill(device: device, queue: queue, kernels: kernels)
    /// Fills computed so far (not found in the cache), for tests.
    private(set) var fillsComputed = 0
    private var mapsMade: UInt64 = 0

    /// The retouched copies kept, for tests.
    var retouchedSessions: [ImageSession] {
        lock.withLock { entries.map(\.retouched) }
    }

    /// Moves whenever a retouched photo's own maps are set, by a still or in the background:
    /// interactive frames read them from then on.
    var mapsGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return mapsMade
    }

    init(device: any MTLDevice, kernels: KernelLibrary, queue: any MTLCommandQueue) {
        self.device = device
        self.kernels = kernels
        self.queue = queue
    }

    /// `session` with the recipe's spots in its pyramid, encoding the work into `commands`
    /// unless it's cached, and its maps as `maps` asks. The session itself when the recipe has none.
    func session(
        for recipe: EditRecipe, base session: ImageSession, commands: any MTLCommandBuffer, maps: Maps = .current,
    ) throws -> ImageSession {
        let original = session.original
        let spots = recipe.spots.filter { !$0.isEmpty }
        guard !spots.isEmpty else { return original }
        let version: FillVersion = recipe.processVersion >= 12 ? .second : .first
        lock.lock()
        defer { lock.unlock() }
        if let index = entries.firstIndex(where: {
            $0.original === original && $0.spots == spots && $0.fills == version
        }) {
            var entry = entries.remove(at: index)
            if maps == .fresh, entry.refreshed == nil {
                try settle(&entry)
                entry.refreshed = try withOwnMaps(original, pyramid: entry.retouched.pyramid)
                mapsMade &+= 1
            }
            entries.append(entry)
            return pick(entry, maps, after: commands)
        }
        // Until its own are made, the maps of this photo's latest retouch that has them, which
        // differ from this one's least (another removal's object doesn't come back meanwhile).
        let latest = entries.last { $0.original === original && $0.refreshed != nil }?.refreshed?.maps
        // Renders wait for their commands, so an evicted copy is free to reuse, once its maps
        // aren't being made. Another photo's still evicts none of the open photo's.
        var reusable: (any MTLTexture)?
        if entries.count(where: { $0.original === original }) >= Self.maximumEntries,
           let index = entries.firstIndex(where: { $0.original === original }) {
            let evicted = entries.remove(at: index)
            if !refreshing.contains(ObjectIdentifier(evicted.retouched.pyramid)) {
                reusable = evicted.retouched.pyramid
            }
        }
        let texture = try reusable ?? makeCopy(of: original.pyramid)
        let baking = try bake(
            spots, of: original, into: texture, fills: version, commands: maps == .fresh ? nil : commands,
        )
        let retouched = ImageSession(retouching: original, pyramid: texture)
        var entry = Entry(
            original: original, spots: spots, fills: version, retouched: retouched,
            interim: latest.map { ImageSession(retouching: original, pyramid: texture, maps: $0) } ?? retouched,
            baking: baking,
        )
        if maps == .fresh {
            entry.refreshed = try withOwnMaps(original, pyramid: texture)
            mapsMade &+= 1
        }
        entries.append(entry)
        return pick(entry, maps, after: commands)
    }

    /// The entry's photo with the maps `maps` asks for, starting their refresh when they aren't
    /// made yet.
    private func pick(_ entry: Entry, _ maps: Maps, after commands: any MTLCommandBuffer) -> ImageSession {
        guard maps != .current else { return entry.retouched }
        if let refreshed = entry.refreshed {
            return refreshed
        }
        refresh(entry, after: commands)
        return entry.interim
    }

    /// Lets go of the retouches and Remove fills of photos other than `session`'s (its variants'
    /// are its own), and of their sessions; of every one, and of the generative fills' bitmaps and
    /// the regions' shapes, when it's nil.
    func keepOnly(_ session: ImageSession?) {
        let photo = session?.photo
        letGo(where: { $0.photo !== photo }, andStored: photo == nil)
    }

    /// Lets go of the retouches and Remove fills of a variant no edit renders from any more
    /// (`RevisionStage`).
    func letGo(ofVariant variant: ImageSession) {
        letGo(where: { $0 === variant }, andStored: false)
    }

    /// Lets go of the retouches and fills of the photos as opened that `drops`, and with `stored`
    /// of the generative fills' bitmaps and the regions' shapes.
    private func letGo(where drops: (ImageSession) -> Bool, andStored stored: Bool) {
        let dropped = lock.withLock {
            let dropped = (
                entries.filter { drops($0.original) }, fills.filter { drops($0.value.owner) },
                stored ? storedFills : [:],
            )
            entries.removeAll { drops($0.original) }
            fills = fills.filter { !drops($0.value.owner) }
            fillOrder.removeAll { fills[$0] == nil }
            if stored {
                storedFills = [:]
                storedOrder = []
                regions = [:]
            }
            return dropped
        }
        // Released once unlocked: a buffer dropped uncommitted runs its completed handlers then.
        withExtendedLifetime(dropped) {}
    }

    /// Forgets the retouches whose spots were going into `commands`, which never ran or failed on
    /// the GPU, so the next render puts them in again.
    func forget(_ commands: any MTLCommandBuffer) {
        let forgotten = lock.withLock {
            let forgotten = entries.filter { $0.baking === commands }
            entries.removeAll { $0.baking === commands }
            return forgotten
        }
        // Released once unlocked: a buffer dropped uncommitted runs its completed handlers then.
        withExtendedLifetime(forgotten) {}
    }

    /// Makes sure the entry's spots are in its pyramid before it's read back: waits for the
    /// command buffer putting them in, or, when that isn't committed yet (a render still being
    /// encoded) or failed, puts them in again in one of its own.
    private func settle(_ entry: inout Entry) throws {
        guard let baking = entry.baking else { return }
        if baking.status == .committed || baking.status == .scheduled {
            baking.waitUntilCompleted()
        }
        if baking.status != .completed {
            _ = try bake(
                entry.spots, of: entry.original, into: entry.retouched.pyramid, fills: entry.fills,
                commands: nil,
            )
        }
        entry.baking = nil
    }

    /// Copies the photo into `texture` and puts the spots in: into `commands`, or with none (or a
    /// Remove spot not filled before) in command buffers of its own, each waited for, its Remove
    /// spots filled as `version` says. Returns the command buffer the work is in while it isn't done.
    private func bake(
        _ spots: [RetouchSpot], of original: ImageSession, into texture: any MTLTexture, fills version: FillVersion,
        commands: (any MTLCommandBuffer)?,
    ) throws -> (any MTLCommandBuffer)? {
        let pyramid = original.pyramid
        let placements = spots.map {
            place($0, orientation: original.orientation, width: pyramid.width, height: pyramid.height)
        }
        let stored = spots.map { storedFill(of: $0, width: pyramid.width, height: pyramid.height) }
        let windows = placements.map { placement in
            placement.flatMap {
                FillWindow($0, levels: pyramid.mipmapLevelCount, width: pyramid.width, height: pyramid.height)
            }
        }
        /// The other spots in a Remove spot's window: those after it, and the Remove spots before it.
        func others(of index: Int) -> (later: [Int], earlier: [Int]) {
            guard version == .second, let window = windows[index] else { return ([], []) }
            let near = spots.indices.filter { $0 != index && placements[$0].map(window.reaches) ?? false }
            return (near.filter { $0 > index }, near.filter { $0 < index && spots[$0].mode == .remove })
        }
        // A Remove spot not filled before reads the photo as the spots before it left it, so the
        // spots are then applied in command buffers of their own, each waited for.
        let keys = spots.indices.map { index in
            spots[index].mode == .remove && stored[index] == nil ? FillKey(
                session: ObjectIdentifier(original), spots: Array(spots[...index]),
                later: others(of: index).later.map { spots[$0] }, version: version,
            ) : nil
        }
        let shared = keys.contains { $0.map { fills[$0] == nil } ?? false } ? nil : commands
        var buffer = try shared ?? makeCommandBuffer()
        guard let blit = buffer.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.label = "Retouch copy"
        blit.copy(
            from: pyramid, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: pyramid.width, height: pyramid.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(),
        )
        blit.endEncoding()
        for (index, spot) in spots.enumerated() {
            guard let placement = placements[index] else { continue }
            if let fill = spot.fill, let bitmap = stored[index] {
                try encodeStoredFill(
                    spot, fill: fill, bitmap: bitmap, noise: original.noise, placement: placement, into: texture,
                    commands: buffer,
                )
                continue
            }
            guard let key = keys[index] else {
                try encode(spot, placement: placement, into: texture, commands: buffer)
                continue
            }
            if fills[key] == nil {
                try generateMipmaps(texture, commands: buffer)
                try finish(buffer)
                let (later, earlier) = others(of: index)
                fills[key] = try windows[index].flatMap { window in
                    try computeFill(
                        placement, window: window, texture: texture, owner: original,
                        avoiding: (later + earlier).compactMap { placements[$0] },
                        replacing: later.compactMap { placements[$0] },
                    )
                }
                fillOrder.append(key)
                if fillOrder.count(where: { $0.session == key.session }) > Self.maximumFills,
                   let index = fillOrder.firstIndex(where: { $0.session == key.session }) {
                    fills[fillOrder.remove(at: index)] = nil
                }
                buffer = try makeCommandBuffer()
            }
            if let map = fills[key] {
                try encodeFill(spot, placement: placement, map: map, into: texture, commands: buffer)
            }
        }
        try generateMipmaps(texture, commands: buffer)
        guard shared == nil else { return shared }
        try finish(buffer)
        return nil
    }

    /// The photo with `pyramid` (its spots already in) and maps made from it.
    private func withOwnMaps(_ original: ImageSession, pyramid: any MTLTexture) throws -> ImageSession {
        let maps = try SessionBuilder.maps(
            of: pyramid, airlight: original.airlight, device: device, queue: queue, kernels: kernels,
        )
        return ImageSession(retouching: original, pyramid: pyramid, maps: maps)
    }

    /// A retouched pyramid on its way to the refresh and back, with the maps made from it. The
    /// pyramid isn't written while it's being refreshed (`refreshing`), and the maps are read once
    /// they're made.
    private struct Refresh: @unchecked Sendable {
        let pyramid: any MTLTexture
        var maps: ImageMaps?
    }

    /// Once `commands` (which puts `entry`'s spots in, or reads them) is done, makes `entry`'s maps
    /// from its pyramid in the background, if it's still the latest retouch, then keeps them and
    /// calls `onRefresh`. A drag's frames refresh only where it stops. Called with `lock` held.
    private func refresh(_ entry: Entry, after commands: any MTLCommandBuffer) {
        let id = ObjectIdentifier(entry.retouched.pyramid)
        guard refreshing.insert(id).inserted else { return }
        let job = Refresh(pyramid: entry.retouched.pyramid)
        let (original, spots, version) = (entry.original, entry.spots, entry.fills)
        commands.addCompletedHandler { [self] commands in
            // A buffer dropped uncommitted or failed on the GPU put no spots in to make maps from.
            let completed = commands.status == .completed
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let latest = lock.withLock {
                    let latest = completed && entries.last?.retouched.pyramid === job.pyramid
                    if !latest {
                        refreshing.remove(id)
                    }
                    return latest
                }
                guard latest else { return }
                var made = job
                made.maps = try? SessionBuilder.maps(
                    of: job.pyramid, airlight: original.airlight, device: device, queue: queue, kernels: kernels,
                )
                let installed = lock.withLock { () -> Bool in
                    refreshing.remove(id)
                    guard let maps = made.maps, let index = entries.firstIndex(where: {
                        $0.retouched.pyramid === made.pyramid && $0.original === original && $0.spots == spots
                            && $0.fills == version
                    }) else { return false }
                    entries[index].baking = nil
                    // A still may have made them meanwhile; the frame on screen still needs them.
                    if entries[index].refreshed == nil {
                        entries[index].refreshed = ImageSession(
                            retouching: original, pyramid: made.pyramid, maps: maps,
                        )
                        mapsMade &+= 1
                    }
                    return true
                }
                if installed {
                    onRefresh?()
                }
            }
        }
    }

    /// Nil when the spot misses the photo.
    static func placement(_ spot: RetouchSpot, orientation: Int, width: Int, height: Int) -> Placement? {
        func texel(_ point: ImagePoint) -> SIMD2<Float> {
            let source = sourceCoordinate(SIMD2(point.x, point.y), orientation: orientation)
            return SIMD2(Float(source.x * Double(width)), Float(source.y * Double(height)))
        }
        let orientedHeight = orientation >= 5 ? width : height
        let radius = Float(min(max(spot.radius, 0), 1) * Double(orientedHeight))
        var points = spot.points().map(texel)
        if points.count > maximumStroke {
            let stride = Double(points.count - 1) / Double(maximumStroke - 1)
            points = (0 ..< maximumStroke).map { points[Int((Double($0) * stride).rounded())] }
        }
        let source = texel(spot.source)
        let finite = { (point: SIMD2<Float>) in
            point.x.isFinite && point.y.isFinite && simd_reduce_max(simd_abs(point)) < 1e7
        }
        guard radius.isFinite, radius > 0, points.allSatisfy(finite), finite(source) else { return nil }
        let low = points.dropFirst().reduce(points[0], simd_min) - radius
        let high = points.dropFirst().reduce(points[0], simd_max) + radius
        let origin = SIMD2(max(Int(floor(low.x)) - 1, 0), max(Int(floor(low.y)) - 1, 0))
        let end = SIMD2(min(Int(ceil(high.x)) + 1, width), min(Int(ceil(high.y)) + 1, height))
        guard end.x > origin.x, end.y > origin.y else { return nil }
        return Placement(
            points: points,
            offset: source - points[0],
            radius: radius,
            origin: origin,
            size: end &- origin,
        )
    }

    /// Where `spot` lands, its region rasterised (and cached) when it has one.
    func place(_ spot: RetouchSpot, orientation: Int, width: Int, height: Int) -> Placement? {
        guard spot.region != nil else {
            return Self.placement(spot, orientation: orientation, width: width, height: height)
        }
        let key = RegionKey(spot: spot, orientation: orientation, width: width, height: height)
        if let cached = regions[key] {
            return cached
        }
        let placement = Self.regionPlacement(spot, orientation: orientation, width: width, height: height)
        if regions.count > 64 {
            regions.removeAll()
        }
        regions[key] = placement
        return placement
    }

    /// A region spot's box and alpha: the mask's bounds in the pyramid, grown by the radius, and the
    /// mask sampled over them, grown with a chamfer distance transform and feathered.
    static func regionPlacement(_ spot: RetouchSpot, orientation: Int, width: Int, height: Int) -> Placement? {
        guard let bitmap = spot.region?.bitmap, let png = bitmap.png, let mask = GrayMask.decode(png),
              mask.width > 0, mask.height > 0
        else { return nil }
        let orientedHeight = orientation >= 5 ? width : height
        let grow = Float(min(max(spot.radius, 0), 1) * Double(orientedHeight))
        func texel(_ point: SIMD2<Double>) -> SIMD2<Float> {
            let source = sourceCoordinate(point, orientation: orientation)
            return SIMD2(Float(source.x * Double(width)), Float(source.y * Double(height)))
        }
        var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
        for y in 0 ..< mask.height {
            for x in 0 ..< mask.width where mask.pixels[y * mask.width + x] >= 128 {
                for corner in [SIMD2(Double(x), Double(y)), SIMD2(Double(x + 1), Double(y + 1))] {
                    let point = texel(corner / SIMD2(Double(mask.width), Double(mask.height)))
                    low = simd_min(low, point)
                    high = simd_max(high, point)
                }
            }
        }
        guard low.x <= high.x else { return nil }
        let origin = SIMD2(max(Int(floor(low.x - grow)) - 2, 0), max(Int(floor(low.y - grow)) - 2, 0))
        let end = SIMD2(min(Int(ceil(high.x + grow)) + 2, width), min(Int(ceil(high.y + grow)) + 2, height))
        guard end.x > origin.x, end.y > origin.y else { return nil }
        let size = end &- origin
        let scale = Float(max(1, Int(ceil(Double(max(size.x, size.y)) / 1024))))
        let (columns, rows) = (Int(ceil(Float(size.x) / scale)), Int(ceil(Float(size.y) / scale)))
        // Inside the mask, sampled at each raster texel's centre (in the photo as shown).
        var distance = [Float](repeating: .infinity, count: columns * rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let level0 = SIMD2(Float(origin.x), Float(origin.y)) + (SIMD2(Float(column), Float(row)) + 0.5) * scale
                let source = SIMD2(Double(level0.x) / Double(width), Double(level0.y) / Double(height))
                let shown = orientedCoordinate(source, orientation: orientation)
                let mx = min(max(Int(shown.x * Double(mask.width)), 0), mask.width - 1)
                let my = min(max(Int(shown.y * Double(mask.height)), 0), mask.height - 1)
                if mask.pixels[my * mask.width + mx] >= 128 {
                    distance[row * columns + column] = 0
                }
            }
        }
        // Chamfer distances (3-4), in raster texels.
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                var d = distance[row * columns + column]
                if column > 0 {
                    d = min(d, distance[row * columns + column - 1] + 1)
                }
                if row > 0 {
                    d = min(d, distance[(row - 1) * columns + column] + 1)
                }
                if row > 0, column > 0 {
                    d = min(d, distance[(row - 1) * columns + column - 1] + 1.4142)
                }
                if row > 0, column < columns - 1 {
                    d = min(d, distance[(row - 1) * columns + column + 1] + 1.4142)
                }
                distance[row * columns + column] = d
            }
        }
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                var d = distance[row * columns + column]
                if column < columns - 1 {
                    d = min(d, distance[row * columns + column + 1] + 1)
                }
                if row < rows - 1 {
                    d = min(d, distance[(row + 1) * columns + column] + 1)
                }
                if row < rows - 1,
                   column < columns - 1 {
                    d = min(d, distance[(row + 1) * columns + column + 1] + 1.4142)
                }
                if row < rows - 1, column > 0 {
                    d = min(d, distance[(row + 1) * columns + column - 1] + 1.4142)
                }
                distance[row * columns + column] = d
            }
        }
        let full = max(grow, 1) / scale
        let solid = full * Float(1 - min(max(spot.feather, 0), 100) / 100)
        let alphas = distance.map { d -> Float in
            guard d < full else { return 0 }
            guard d > solid else { return 1 }
            let t = (d - solid) / max(full - solid, 1e-3)
            return 1 - t * t * (3 - 2 * t)
        }
        // The edge: texels just outside the alpha's reach, beside one inside it.
        var rim: [SIMD2<Float>] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns where alphas[row * columns + column] == 0 {
                let inside = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { dx, dy in
                    let (x, y) = (column + dx, row + dy)
                    return x >= 0 && y >= 0 && x < columns && y < rows && alphas[y * columns + x] > 0
                }
                if inside {
                    rim
                        .append(SIMD2(Float(origin.x), Float(origin.y)) + (SIMD2(Float(column), Float(row)) + 0.5) *
                            scale)
                }
            }
        }
        guard !rim.isEmpty else { return nil }
        var spacing = scale
        if rim.count > maximumOutline {
            let stride = Float(rim.count) / Float(maximumOutline)
            rim = (0 ..< maximumOutline).map { rim[min(Int(Float($0) * stride), rim.count - 1)] }
            spacing *= stride
        }
        let center = (low + high) / 2
        var placement = Placement(
            points: [center], offset: texel(SIMD2(spot.source.x, spot.source.y)) - texel(SIMD2(
                spot.center.x,
                spot.center.y,
            )),
            radius: max(grow, 1), origin: origin, size: size,
        )
        placement.region = Region(
            width: columns, height: rows, scale: scale, alphas: alphas, rim: rim, spacing: spacing,
        )
        return placement
    }

    /// Points on the edge of the spot's shape, about evenly spaced, and their spacing: a circle's
    /// rim, the outline of the discs along a stroke (a quarter radius apart), or a region's edge.
    static func outline(_ placement: Placement) -> (points: [SIMD2<Float>], spacing: Float) {
        if let region = placement.region {
            return (region.rim, region.spacing)
        }
        let radius = placement.radius
        guard placement.points.count > 1 else {
            let count = rimSamples
            let points = (0 ..< count).map { index in
                let angle = 2 * Float.pi * (Float(index) + 0.5) / Float(count)
                return placement.center + radius * SIMD2(cos(angle), sin(angle))
            }
            return (points, 2 * .pi * radius / Float(count))
        }
        var dabs = [placement.points[0]]
        for next in placement.points.dropFirst() {
            let last = dabs[dabs.count - 1]
            let steps = max(Int(ceil(simd_distance(last, next) / (radius / 4))), 1)
            for step in 1 ... steps {
                dabs.append(last + (next - last) * Float(step) / Float(steps))
            }
        }
        let perDab = min(max(Int(ceil(2 * Float.pi * radius)), 32), 128)
        let directions = (0 ..< perDab).map { index in
            let angle = 2 * Float.pi * (Float(index) + 0.5) / Float(perDab)
            return radius * SIMD2(cos(angle), sin(angle))
        }
        var points: [SIMD2<Float>] = []
        let reach2 = 4 * radius * radius, inside2 = radius * radius * 0.998
        for (index, dab) in dabs.enumerated() {
            let neighbours = dabs.indices.filter { $0 != index && simd_distance_squared(dabs[$0], dab) < reach2 }
            for direction in directions {
                let point = dab + direction
                if neighbours.allSatisfy({ simd_distance_squared(dabs[$0], point) >= inside2 }) {
                    points.append(point)
                }
            }
        }
        var spacing = 2 * .pi * radius / Float(perDab)
        if points.count > maximumOutline {
            let stride = Float(points.count) / Float(maximumOutline)
            points = (0 ..< maximumOutline).map { points[min(Int(Float($0) * stride), points.count - 1)] }
            spacing *= stride
        }
        return (points, spacing)
    }

    private func makeCopy(of pyramid: any MTLTexture) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pyramid.pixelFormat, width: pyramid.width, height: pyramid.height, mipmapped: true,
        )
        descriptor.mipmapLevelCount = pyramid.mipmapLevelCount
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        texture.label = "Retouched pyramid"
        return texture
    }

    private func makeCommandBuffer() throws -> any MTLCommandBuffer {
        guard let buffer = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
        buffer.label = "Retouch"
        return buffer
    }

    private func finish(_ buffer: any MTLCommandBuffer) throws {
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }
    }

    private func generateMipmaps(_ texture: any MTLTexture, commands: any MTLCommandBuffer) throws {
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
    }

    /// How far `point` is from the stroke (from the point, for a circle).
    static func strokeDistance(_ point: SIMD2<Float>, _ stroke: [SIMD2<Float>]) -> Float {
        var nearest = simd_distance(point, stroke[0])
        for index in stroke.indices.dropFirst() {
            let a = stroke[index - 1], ab = stroke[index] - a
            let t = min(max(simd_dot(point - a, ab) / max(simd_length_squared(ab), 1e-6), 0), 1)
            nearest = min(nearest, simd_distance(point, a + ab * t))
        }
        return nearest
    }

    /// Fills the spot's hole (`ContentAwareFill`) in its window, read back from `texture` as it
    /// now is, copying from none of `avoiding` and matching on none of `replacing`.
    private func computeFill(
        _ placement: Placement, window: FillWindow, texture: any MTLTexture, owner: ImageSession,
        avoiding: [Placement], replacing: [Placement],
    ) throws -> FillMap? {
        fillsComputed += 1
        let (level, scale) = (window.level, window.scale)
        let (x0, y0) = (window.low.x, window.low.y)
        let (width, height) = (window.high.x - window.low.x, window.high.y - window.low.y)
        guard let readback = device.makeBuffer(length: width * height * 8, options: .storageModeShared) else {
            throw EngineError.gpuUnavailable
        }
        let commands = try makeCommandBuffer()
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
            destinationBytesPerRow: width * 8, destinationBytesPerImage: width * height * 8,
        )
        blit.endEncoding()
        try finish(commands)
        let halves = readback.contents().assumingMemoryBound(to: Float16.self)
        var pixels: [SIMD3<Float>] = []
        var hole: [Bool] = []
        pixels.reserveCapacity(width * height)
        hole.reserveCapacity(width * height)
        var avoided = avoiding.isEmpty ? [] : [Bool](repeating: false, count: width * height)
        var replaced = replacing.isEmpty ? [] : [Bool](repeating: false, count: width * height)
        /// Texels whose centre a spot covers, or is within three quarters of a texel of.
        func covers(_ spot: Placement, _ centre: SIMD2<Float>) -> Bool {
            spot.covers(centre, reach: spot.radius + 0.75 * scale)
        }
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let rgb = SIMD3(Float(halves[index]), Float(halves[index + 1]), Float(halves[index + 2]))
                pixels.append(simd_max(rgb, .zero).squareRoot())
                let centre = (SIMD2(Float(x0 + x), Float(y0 + y)) + 0.5) * scale
                hole.append(covers(placement, centre))
                if !avoided.isEmpty {
                    avoided[y * width + x] = avoiding.contains { covers($0, centre) }
                }
                if !replaced.isEmpty {
                    replaced[y * width + x] = replacing.contains { covers($0, centre) }
                }
            }
        }
        let moves = try filler.fill(ContentAwareFill.Region(
            width: width, height: height, pixels: pixels, hole: hole, avoided: avoided, replaced: replaced,
        ))
        // Around the hole, each texel takes the nearest hole texel's move, so the fill reaches
        // the spot's rim, where Heal's seams are measured.
        var offsets = moves.map { SIMD2(Float($0.x), Float($0.y)) * scale }
        var assigned = hole
        for _ in 0 ..< 8 {
            let before = assigned
            for y in 0 ..< height {
                for x in 0 ..< width where !before[y * width + x] {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let (nx, ny) = (x + dx, y + dy)
                        guard nx >= 0, ny >= 0, nx < width, ny < height, before[ny * width + nx] else { continue }
                        offsets[y * width + x] = offsets[ny * width + nx]
                        assigned[y * width + x] = true
                        break
                    }
                }
            }
        }
        return FillMap(
            level: level, origin: SIMD2(x0, y0), size: SIMD2(width, height), offsets: offsets, owner: owner,
        )
    }

    /// Renders the fill at full resolution from its moves (`rl_fill_render`), then blends it in as
    /// Heal does, so its edge matches the photo around it.
    private func encodeFill(
        _ spot: RetouchSpot, placement: Placement, map: FillMap, into texture: any MTLTexture,
        commands: any MTLCommandBuffer,
    ) throws {
        let scale = 1 << map.level
        let margin = 8
        let origin = SIMD2(max(placement.origin.x - margin, 0), max(placement.origin.y - margin, 0))
        let end = SIMD2(
            min(placement.origin.x + placement.size.x + margin, texture.width),
            min(placement.origin.y + placement.size.y + margin, texture.height),
        )
        guard end.x > origin.x, end.y > origin.y else { return }
        let size = end &- origin
        let offsetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: map.size.x, height: map.size.y, mipmapped: false,
        )
        offsetDescriptor.usage = [.shaderRead]
        offsetDescriptor.storageMode = .shared
        let fillDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: size.x, height: size.y, mipmapped: false,
        )
        fillDescriptor.usage = [.shaderRead, .shaderWrite]
        fillDescriptor.storageMode = .private
        guard let offsets = device.makeTexture(descriptor: offsetDescriptor),
              let fill = device.makeTexture(descriptor: fillDescriptor),
              let encoder = commands.makeComputeCommandEncoder()
        else { throw EngineError.gpuUnavailable }
        map.offsets.withUnsafeBytes { bytes in
            offsets.replace(
                region: MTLRegionMake2D(0, 0, map.size.x, map.size.y), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: map.size.x * MemoryLayout<SIMD2<Float>>.stride,
            )
        }
        encoder.label = "Fill"
        var params = FillRenderParams(
            box: SIMD4(Int32(origin.x), Int32(origin.y), Int32(size.x), Int32(size.y)),
            offsets: SIMD4(
                Int32(map.origin.x * scale), Int32(map.origin.y * scale), Int32(map.size.x), Int32(map.size.y),
            ),
            scale: SIMD4(Float(scale), 0, 0, 0),
        )
        encoder.setComputePipelineState(kernels.fillRender)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(offsets, index: 1)
        encoder.setTexture(fill, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<FillRenderParams>.stride, index: 0)
        encoder.dispatchGrid(width: size.x, height: size.y, pipeline: kernels.fillRender)
        encoder.endEncoding()
        try encode(spot, placement: placement, into: texture, commands: commands, fill: (fill, origin))
    }

    /// A Remove spot's generative fill on the GPU, when it has one made for a photo this size whose
    /// bitmap is loaded; otherwise the spot is filled from the photo. Called with `lock` held.
    private func storedFill(of spot: RetouchSpot, width: Int, height: Int) -> (any MTLTexture)? {
        guard spot.mode == .remove, let fill = spot.fill, fill.photoSize == PixelSize(width: width, height: height),
              let png = fill.bitmap.png
        else { return nil }
        if let texture = storedFills[fill.bitmap.sha256] {
            return texture
        }
        guard let decoded = GeneratedFillCodec.decode(png) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: decoded.width, height: decoded.height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let halves = decoded.values.map(Float16.init)
        halves.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, decoded.width, decoded.height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: decoded.width * 8,
            )
        }
        storedFills[fill.bitmap.sha256] = texture
        storedOrder.append(fill.bitmap.sha256)
        if storedOrder.count > 16 {
            storedFills[storedOrder.removeFirst()] = nil
        }
        return texture
    }

    /// Renders a generative fill at full resolution (`rl_fill_stored`), with the photo's noise,
    /// then blends it in as Heal does.
    private func encodeStoredFill(
        _ spot: RetouchSpot, fill: GeneratedFill, bitmap: any MTLTexture, noise: NoiseModel, placement: Placement,
        into texture: any MTLTexture, commands: any MTLCommandBuffer,
    ) throws {
        let margin = 8
        let origin = SIMD2(max(placement.origin.x - margin, 0), max(placement.origin.y - margin, 0))
        let end = SIMD2(
            min(placement.origin.x + placement.size.x + margin, texture.width),
            min(placement.origin.y + placement.size.y + margin, texture.height),
        )
        guard end.x > origin.x, end.y > origin.y else { return }
        let size = end &- origin
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: size.x, height: size.y, mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let scratch = device.makeTexture(descriptor: descriptor),
              let encoder = commands.makeComputeCommandEncoder()
        else { throw EngineError.gpuUnavailable }
        encoder.label = "Generated fill"
        var params = FillStoredParams(
            box: SIMD4(Int32(origin.x), Int32(origin.y), Int32(size.x), Int32(size.y)),
            fill: SIMD4(Int32(fill.box.x), Int32(fill.box.y), Int32(fill.box.width), Int32(fill.box.height)),
            noiseA: SIMD4(noise.a, 0), noiseB: SIMD4(noise.b, 0),
            peak: SIMD4(Float(fill.peak), Float(bitPattern: UInt32(truncatingIfNeeded: fill.seed)), 0, 0),
        )
        encoder.setComputePipelineState(kernels.fillStored)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(bitmap, index: 1)
        encoder.setTexture(scratch, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<FillStoredParams>.stride, index: 0)
        encoder.dispatchGrid(width: size.x, height: size.y, pipeline: kernels.fillStored)
        encoder.endEncoding()
        try encode(spot, placement: placement, into: texture, commands: commands, fill: (scratch, origin))
    }

    /// Writes the spot into a scratch texture, then copies that over the pyramid, so a source
    /// overlapping the destination reads the photo before the spot. With `fill`, the replacement
    /// comes from that texture (placed at its origin) and is always healed in.
    private func encode(
        _ spot: RetouchSpot, placement: Placement, into texture: any MTLTexture, commands: any MTLCommandBuffer,
        fill: (texture: any MTLTexture, origin: SIMD2<Int>)? = nil,
    ) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: placement.size.x, height: placement.size.y, mipmapped: false,
        )
        descriptor.usage = [.shaderWrite]
        descriptor.storageMode = .private
        let heal = spot.mode == .heal || fill != nil
        let outline = heal ? Self.outline(placement) : (points: [placement.center], spacing: 1)
        let point = MemoryLayout<SIMD2<Float>>.stride
        let ratioLength = outline.points.count * MemoryLayout<SIMD4<Float>>.stride
        guard let scratch = device.makeTexture(descriptor: descriptor),
              let ratios = device.makeBuffer(length: ratioLength, options: .storageModePrivate),
              let filtered = device.makeBuffer(length: ratioLength, options: .storageModePrivate),
              let rim = device.makeBuffer(
                  bytes: outline.points, length: outline.points.count * point, options: .storageModeShared,
              ),
              let stroke = device.makeBuffer(
                  bytes: placement.points, length: placement.points.count * point, options: .storageModeShared,
              )
        else { throw EngineError.gpuUnavailable }
        try commands.withComputeEncoder { encoder in
            encoder.label = "Retouch"
            let box = SIMD4<Int32>(
                Int32(placement.origin.x), Int32(placement.origin.y), Int32(placement.size.x), Int32(placement.size.y),
            )
            let featherStart = Float(1 - min(max(spot.feather, 0), 100) / 100)
            let opacity = Float(min(max(spot.opacity, 0), 100) / 100)
            var params = RetouchParams(
                box: box,
                shape: SIMD4<Float>(placement.radius, featherStart, outline.spacing, placement.radius / 2),
                source: fill.map { SIMD4<Float>(Float($0.origin.x), Float($0.origin.y), opacity, 1) }
                    ?? SIMD4<Float>(placement.offset.x, placement.offset.y, opacity, heal ? 1 : 0),
                counts: SIMD4<Int32>(
                    Int32(outline.points.count), Int32(placement.points.count), fill == nil ? 0 : 1, 0,
                ),
            )
            var alphaTexture: (any MTLTexture)?
            if let region = placement.region {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r32Float, width: region.width, height: region.height, mipmapped: false,
                )
                descriptor.usage = [.shaderRead]
                descriptor.storageMode = .shared
                guard let alpha = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
                region.alphas.withUnsafeBytes { bytes in
                    alpha.replace(
                        region: MTLRegionMake2D(0, 0, region.width, region.height), mipmapLevel: 0,
                        withBytes: bytes.baseAddress!, bytesPerRow: region.width * MemoryLayout<Float>.stride,
                    )
                }
                alphaTexture = alpha
                params.counts.w = 1
            }
            encoder.setTexture(texture, index: 0)
            encoder.setTexture(fill?.texture ?? texture, index: 2)
            encoder.setTexture(alphaTexture ?? texture, index: 3)
            encoder.setBytes(&params, length: MemoryLayout<RetouchParams>.stride, index: 0)
            encoder.setBuffer(ratios, offset: 0, index: 1)
            encoder.setBuffer(rim, offset: 0, index: 2)
            encoder.setBuffer(stroke, offset: 0, index: 3)
            if heal {
                encoder.setComputePipelineState(kernels.retouchRim)
                encoder.dispatchGrid(width: outline.points.count, height: 1, pipeline: kernels.retouchRim)
                encoder.setBuffer(filtered, offset: 0, index: 4)
                encoder.setComputePipelineState(kernels.retouchRimMedian)
                encoder.dispatchGrid(width: outline.points.count, height: 1, pipeline: kernels.retouchRimMedian)
                encoder.setBuffer(filtered, offset: 0, index: 1)
            }
            encoder.setComputePipelineState(kernels.retouchApply)
            encoder.setTexture(scratch, index: 1)
            encoder.dispatchGrid(width: placement.size.x, height: placement.size.y, pipeline: kernels.retouchApply)
        }
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.copy(
            from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: placement.size.x, height: placement.size.y, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: placement.origin.x, y: placement.origin.y, z: 0),
        )
        blit.endEncoding()
    }
}
