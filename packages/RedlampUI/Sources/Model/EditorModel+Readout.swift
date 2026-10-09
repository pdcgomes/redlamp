import Foundation
import RedlampEngineAPI

/// The histogram's readout (UX-32): the values of the photo under the pointer, made by the engine
/// from the edit the canvas shows, without its overlays.
public extension EditorModel {
    /// The pointer moved over the canvas: `point` is the photo point under it, as the canvas
    /// reports clicks, nil once it leaves the photo.
    func hoverReadout(at point: CGPoint?) {
        readoutPoint = point
        guard point != nil else {
            pixelReadout = nil
            return
        }
        refreshReadout()
    }

    /// The readout line's parts: "R 45.2", "G 44.8", "B 44.9 %", or "L* 50.9", "a* −0.3", "b* 0.8"; under
    /// Redlamp Reproduction then the stops, "+0.08 EV", which an `approximate` (typical) anchor marks "≈".
    static func readoutParts(_ readout: PixelReadout, lab: Bool, approximate: Bool = false) -> [String] {
        func number(_ value: Double, format: String = "%.1f") -> String {
            let text = String(format: format, value)
            guard Double(text) != 0 else { return String(format: format.replacingOccurrences(of: "+", with: ""), 0.0) }
            return text.replacingOccurrences(of: "-", with: "−")
        }
        var parts = lab
            ? ["L* \(number(readout.lab.x))", "a* \(number(readout.lab.y))", "b* \(number(readout.lab.z))"]
            : ["R \(number(readout.rgb.x))", "G \(number(readout.rgb.y))", "B \(number(readout.rgb.z)) %"]
        if let stops = readout.stops {
            parts.append("\(approximate ? "≈ " : "")\(number(stops, format: "%+.2f")) EV")
        }
        return parts
    }

    /// The readout's stops count from the typical anchor, not a calibration.
    var readoutIsApproximate: Bool {
        info?.isRaw == true && readoutRecipe?.exposureAnchor?.source != .target
    }
}

extension EditorModel {
    /// The side of the square a readout averages, in pixels as displayed.
    static let readoutPixels = 5.0

    /// Asks for a readout of the point under the pointer with the edit the canvas shows; one at a
    /// time, the latest point and edit winning.
    func refreshReadout() {
        guard readoutPoint != nil, readoutRecipe != nil else { return }
        guard readoutTask == nil else {
            readoutStale = true
            return
        }
        readoutTask = Task { [weak self] in
            await self?.makeReadouts()
        }
    }

    private func makeReadouts() async {
        while let point = readoutPoint, let recipe = readoutRecipe, let visit = currentVisit {
            readoutStale = false
            let readout = await engine.readout(at: point, area: readoutArea, recipe: recipe)
            if readoutPoint != nil, currentVisit == visit {
                pixelReadout = readout
            }
            guard readoutStale else { break }
        }
        readoutTask = nil
    }

    /// `readoutPixels` square of the photo as displayed, in fractions of the frame.
    private var readoutArea: CGSize {
        let shown = canvas.imageRect(in: canvas.viewSize)
        let scale = max(canvas.backingScale, 1)
        guard shown.width > 0, shown.height > 0 else { return CGSize(width: 0.004, height: 0.004) }
        return CGSize(
            width: Self.readoutPixels / (shown.width * scale),
            height: Self.readoutPixels / (shown.height * scale),
        )
    }
}
