import CoreGraphics
import RedlampEngineAPI
import simd

/// Face Skin's forehead: grown up from the landmarks' outline to the hairline.
extension FaceParts.Face {
    /// The most lightness may change from one pixel of the forehead to the next.
    static let lightnessStep: Float = 0.035

    /// `face` with its forehead grown up from it through pixels of the forehead's own colour
    /// (`SkinColour`, from just above the brows), within a dome over the brows as wide as the face
    /// outline and reaching four fifths of the brows' height above the chin. It stops at the
    /// hairline, a hat or a fringe, where a fixed height would stop short of a high one, and a bald
    /// head's skin keeps going. Shading changes lightness gradually and a hairline in a step, so
    /// growth follows the one and stops at the other, on lightness a little blurred so pores don't
    /// stop it. What grows is opened by a sixth of an eye, so strands of hair the colour lets through
    /// don't carry it on into the hair, and holes smaller than an eye (a highlight, a mole) are filled.
    func foreheadSkin(_ face: GrayMask, pixels: RGBImage) -> GrayMask? {
        let xs = contour.map(\.x)
        let eyeXs = eyes.joined().map(\.x)
        guard let left = xs.min(), let right = xs.max(), let chin = contour.map(\.y).min(),
              let eyesLeft = eyeXs.min(), let eyesRight = eyeXs.max(),
              pixels.width == size.width, pixels.height == size.height
        else { return nil }
        let top = browTop
        let reach = (top - chin) * 0.8
        guard reach > 0, right > left, eyeWidth > 0,
              let strip = FaceParts.draw(size, { context in
                  context.fill(CGRect(x: eyesLeft, y: top, width: eyesRight - eyesLeft, height: eyeWidth * 0.9))
              }),
              let colour = FaceParts.SkinColour(strip.intersection(face), pixels: pixels),
              let dome = FaceParts.draw(size, { context in
                  context.fillEllipse(in: CGRect(x: left, y: top - reach, width: right - left, height: 2 * reach))
                  context.setBlendMode(.clear)
                  context.fill(CGRect(x: 0, y: 0, width: CGFloat(size.width), height: top))
              })
        else { return nil }
        let region = ForeheadRegion(
            width: size.width, height: size.height, open: dome.pixels.map { $0 > 127 },
            base: face.pixels.map { $0 > 127 },
        )
        let lightness = BoxFilter.blur(
            (0 ..< size.width * size.height).map { pixels.rgb($0 % size.width, $0 / size.width).sum() / 3 },
            width: size.width, height: size.height, radius: 1,
        )
        let skinlike = region.open.indices.map {
            region.open[$0] && colour.matches(pixels.rgb($0 % size.width, $0 / size.width))
        }
        let grown = region.reached { from, to in
            skinlike[to] && abs(lightness[to] - lightness[from]) <= Self.lightnessStep
        }
        let forehead = region.filled(
            region.opened(grown, radius: max(1, Int((eyeWidth / 6).rounded()))),
            largestHole: Int(eyeWidth * eyeWidth),
        )
        var skin = face.pixels
        for index in forehead.indices where forehead[index] {
            skin[index] = 255
        }
        return GrayMask(width: size.width, height: size.height, pixels: skin)
    }
}

/// Where a forehead may grow (`open`), from what (`base`), in mask pixels top-left first.
struct ForeheadRegion {
    let width: Int
    let height: Int
    let open: [Bool]
    let base: [Bool]

    func neighbours(_ index: Int) -> [Int] {
        let x = index % width
        let y = index / width
        return [
            x > 0 ? index - 1 : -1, x < width - 1 ? index + 1 : -1,
            y > 0 ? index - width : -1, y < height - 1 ? index + width : -1,
        ]
    }

    /// `base` and every pixel a path of steps `allowed` joins to it.
    func reached(_ allowed: (_ from: Int, _ to: Int) -> Bool) -> [Bool] {
        var seen = base
        var stack = seen.indices.filter { seen[$0] }
        while let index = stack.popLast() {
            for next in neighbours(index) where next >= 0 && !seen[next] && allowed(index, next) {
                seen[next] = true
                stack.append(next)
            }
        }
        return seen
    }

    /// `grown` worn away and grown back by `radius`, its square corners rounded (blurred by as
    /// much and cut at half), and joined to `base` again.
    func opened(_ grown: [Bool], radius: Int) -> [Bool] {
        let worn = BoxFilter.blur(grown.map { $0 ? 1 : 0 }, width: width, height: height, radius: radius)
            .map { $0 > 0.999 ? Float(1) : 0 }
        let regrown = BoxFilter.blur(worn, width: width, height: height, radius: radius)
        let rounded = BoxFilter.blur(
            grown.indices.map { grown[$0] && regrown[$0] > 0.001 ? 1 : 0 }, width: width, height: height,
            radius: radius,
        )
        return reached { _, to in rounded[to] > 0.5 }
    }

    /// `grown` with its holes filled: the pieces of `open` left out, of up to `largestHole`
    /// pixels, that no path of left-out pixels joins to the edge of `open`.
    func filled(_ grown: [Bool], largestHole: Int) -> [Bool] {
        var filled = grown
        var visited = [Bool](repeating: false, count: grown.count)
        for start in grown.indices where open[start] && !grown[start] && !visited[start] {
            var piece = [start]
            var touchesEdge = false
            visited[start] = true
            var cursor = 0
            while cursor < piece.count {
                for next in neighbours(piece[cursor]) {
                    if next < 0 || !open[next] {
                        touchesEdge = true
                    } else if !grown[next], !visited[next] {
                        visited[next] = true
                        piece.append(next)
                    }
                }
                cursor += 1
            }
            if !touchesEdge, piece.count <= largestHole {
                piece.forEach { filled[$0] = true }
            }
        }
        return filled
    }
}

extension FaceParts {
    /// The colour of a face's skin, from the pixels under its mask: the median and spread of their
    /// chromaticity (red and green over the sum, which shading doesn't change) and lightness.
    struct SkinColour {
        let median: SIMD3<Float>
        let spread: SIMD3<Float>

        static func features(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
            let sum = max(rgb.sum(), 1e-3)
            return SIMD3(rgb.x / sum, rgb.y / sum, sum / 3)
        }

        init?(_ mask: GrayMask, pixels: RGBImage) {
            var samples: [SIMD3<Float>] = []
            for index in stride(from: 0, to: mask.pixels.count, by: 3) where mask.pixels[index] > 127 {
                samples.append(Self.features(pixels.rgb(index % mask.width, index / mask.width)))
            }
            guard samples.count >= 50 else { return nil }
            func middle(_ values: [Float]) -> Float {
                values.sorted()[values.count / 2]
            }
            let centre = SIMD3(middle(samples.map(\.x)), middle(samples.map(\.y)), middle(samples.map(\.z)))
            let deviation = SIMD3(
                middle(samples.map { abs($0.x - centre.x) }), middle(samples.map { abs($0.y - centre.y) }),
                middle(samples.map { abs($0.z - centre.z) }),
            )
            median = centre
            // 1.4826 times the median deviation is a normal distribution's standard deviation; the
            // floors keep evenly lit skin from turning away its own pores and freckles.
            spread = simd_max(deviation * 1.4826, SIMD3(0.012, 0.008, 0.05))
        }

        /// Within four spreads of the skin's chromaticity, and no darker than four spreads below its
        /// lightness nor brighter than six above: shading and highlights pass, grey and dark hair
        /// mostly don't, and the step between pixels stops the rest.
        func matches(_ rgb: SIMD3<Float>) -> Bool {
            let distance = (Self.features(rgb) - median) / spread
            return distance.x * distance.x + distance.y * distance.y <= 16 && distance.z >= -4 && distance.z <= 6
        }
    }
}
