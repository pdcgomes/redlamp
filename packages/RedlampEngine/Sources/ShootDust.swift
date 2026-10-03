import Foundation
import RedlampEngineAPI
import simd

/// Dust across a shoot (RM-02): dust sits in the same place on the sensor in every frame, the
/// scene doesn't. Specks found in several frames, in the same sensor place and of about the same
/// size, are dust, and are placed in every frame from that sensor, where texture hid them too.
enum ShootDust {
    struct Frame {
        var url: URL
        var recipe: EditRecipe
        var session: ImageSession
        /// As `findDust` found them, in the photo as shown.
        var specks: [DetectedSpot]
    }

    /// A speck in sensor texels (level 0 of the pyramid, before orientation).
    struct SensorSpeck {
        var frame: Int
        var center: SIMD2<Float>
        var radius: Float
        var strength: Double
    }

    /// Found in at least this many frames, and this share of them.
    static let minimumFrames = 2
    static let minimumShare = 0.2

    static func consistent(_ frames: [Frame]) -> [URL: [DetectedSpot]] {
        var result: [URL: [DetectedSpot]] = [:]
        // Frames from one sensor, and at one size, can be compared.
        let groups = Dictionary(grouping: frames.indices) { index in
            let pyramid = frames[index].session.pyramid
            return "\(frames[index].session.info.make ?? "")|\(frames[index].session.info.model ?? "")|\(pyramid.width)x\(pyramid.height)"
        }
        for indices in groups.values {
            let specks = indices.flatMap { index in
                frames[index].specks.map { sensor($0, in: frames[index], frame: index) }
            }
            let needed = max(minimumFrames, Int(ceil(minimumShare * Double(indices.count))))
            for cluster in clusters(specks) {
                let seen = Set(cluster.map(\.frame))
                guard seen.count >= needed else { continue }
                let center = SIMD2(median(cluster.map(\.center.x)), median(cluster.map(\.center.y)))
                let radius = (cluster.map(\.radius).max() ?? 0) * 1.1
                let strength = cluster.map(\.strength).reduce(0, +) / Double(cluster.count)
                for index in indices {
                    let frame = frames[index]
                    guard let spot = shown(center, radius: radius, strength: strength, in: frame), !covered(spot, frame)
                    else { continue }
                    result[frame.url, default: []].append(spot)
                }
            }
        }
        return result
    }

    private static func sensor(_ spot: DetectedSpot, in frame: Frame, frame index: Int) -> SensorSpeck {
        let pyramid = frame.session.pyramid
        let orientation = frame.session.orientation
        let source = sourceCoordinate(SIMD2(spot.center.x, spot.center.y), orientation: orientation)
        let height = Double(orientation >= 5 ? pyramid.width : pyramid.height)
        return SensorSpeck(
            frame: index,
            center: SIMD2(Float(source.x * Double(pyramid.width)), Float(source.y * Double(pyramid.height))),
            radius: Float(spot.radius * height), strength: spot.strength,
        )
    }

    private static func shown(
        _ center: SIMD2<Float>,
        radius: Float,
        strength: Double,
        in frame: Frame,
    ) -> DetectedSpot? {
        let pyramid = frame.session.pyramid
        let orientation = frame.session.orientation
        let point = orientedCoordinate(
            SIMD2(Double(center.x) / Double(pyramid.width), Double(center.y) / Double(pyramid.height)),
            orientation: orientation,
        )
        let height = Double(orientation >= 5 ? pyramid.width : pyramid.height)
        guard point.x >= 0, point.y >= 0, point.x <= 1, point.y <= 1 else { return nil }
        return DetectedSpot(
            center: ImagePoint(x: point.x, y: point.y),
            radius: Double(radius) / height,
            strength: strength,
        )
    }

    /// Whether the frame's own spots already cover the speck.
    private static func covered(_ spot: DetectedSpot, _ frame: Frame) -> Bool {
        let size = frame.session.orientedSize
        let aspect = Double(size.width) / Double(max(size.height, 1))
        return frame.recipe.spots.contains { existing in
            existing.points().contains { point in
                hypot((point.x - spot.center.x) * aspect, point.y - spot.center.y) < existing.radius + spot.radius * 0.5
            }
        }
    }

    /// Specks that are the same speck: within most of the larger one's radius of each other and
    /// no more than twice its size, linked into groups.
    private static func clusters(_ specks: [SensorSpeck]) -> [[SensorSpeck]] {
        var parent = Array(specks.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for a in specks.indices {
            for b in specks.indices where b > a && specks[a].frame != specks[b].frame {
                let larger = max(specks[a].radius, specks[b].radius), smaller = min(specks[a].radius, specks[b].radius)
                guard simd_distance(specks[a].center, specks[b].center) < larger * 0.8 + 2, larger <= smaller * 2
                else { continue }
                parent[root(a)] = root(b)
            }
        }
        return Dictionary(grouping: specks.indices, by: root).values.map { $0.map { specks[$0] } }
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
