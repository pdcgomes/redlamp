import CoreGraphics
import Foundation
import simd

public extension CaptureLayout {
    /// The chart as sRGB-encoded floats. `tiles` fill the photo tiles in order, cropped to
    /// fill; missing tiles stay grey.
    func pixels(chart: Int, tiles: [PixelImage] = []) -> PixelImage {
        let grey = CaptureChart.quantized(CaptureChart.surroundGrey)
        var image = PixelImage(
            width: side, height: side,
            pixels: [SIMD3<Float>](repeating: SIMD3(repeating: grey), count: side * side),
        )
        for patch in patches(chart: chart) {
            Self.fill(&image, patch.rect, nodeValue(patch.node))
        }
        let unit = CGFloat(markerModule)
        for centre in markerCentres {
            let box = markerRect(centre)
            Self.fill(&image, box, SIMD3(repeating: 1))
            Self.fill(&image, box.insetBy(dx: unit, dy: unit), .zero)
            Self.fill(&image, box.insetBy(dx: 2 * unit, dy: 2 * unit), SIMD3(repeating: 1))
            Self.fill(&image, box.insetBy(dx: 3 * unit, dy: 3 * unit), .zero)
        }
        let code = barcode(chart: chart)
        for copy in barcodeCopies {
            for (rect, black) in zip(copy, code) {
                Self.fill(&image, rect, SIMD3(repeating: black ? 0 : 1))
            }
        }
        drawRamp(&image)
        drawLinePairs(&image)
        drawTiles(&image, tiles)
        return image
    }

    private func drawRamp(_ image: inout PixelImage) {
        for y in Int(rampRect.minY) ..< Int(rampRect.maxY) {
            for x in Int(rampRect.minX) ..< Int(rampRect.maxX) {
                image[x, y] = SIMD3(repeating: rampLevel(x: Float(x) + 0.5))
            }
        }
    }

    private func drawLinePairs(_ image: inout PixelImage) {
        for group in linePairs {
            for y in Int(group.rect.minY) ..< Int(group.rect.maxY) {
                for x in Int(group.rect.minX) ..< Int(group.rect.maxX) {
                    let phase = (Float(x) + 0.5 - Float(group.rect.minX)) / group.period
                    image[x, y] = SIMD3(repeating: phase - phase.rounded(.down) < 0.5 ? 0 : 1)
                }
            }
        }
    }

    private func drawTiles(_ image: inout PixelImage, _ tiles: [PixelImage]) {
        for (rect, tile) in zip(photoTiles, tiles) {
            let fitted = PhotoPairAnalysis.cropped(tile, toAspect: Float(rect.width / rect.height))
            guard let sized = fitted.width == Int(rect.width) && fitted.height == Int(rect.height)
                ? fitted
                : PhotoPairAnalysis.resampled(fitted, width: Int(rect.width), height: Int(rect.height))
            else { continue }
            for y in 0 ..< sized.height {
                for x in 0 ..< sized.width {
                    image[Int(rect.minX) + x, Int(rect.minY) + y] = sized[x, y]
                }
            }
        }
    }

    private static func fill(_ image: inout PixelImage, _ rect: CGRect, _ color: SIMD3<Float>) {
        for y in Int(rect.minY) ..< Int(rect.maxY) {
            for x in Int(rect.minX) ..< Int(rect.maxX) {
                image[x, y] = color
            }
        }
    }
}
