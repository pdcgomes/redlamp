import Foundation
import RedlampEngineAPI

/// The brush that `[`, `]` and ⌘-scroll size: the one whose tool is active (UX-15).
public enum SizedBrush: Equatable, Sendable {
    /// The Masking tool's A, B or Erase brush.
    case mask
    /// The Refine Edge brush.
    case edge
    /// The Healing tool's brush, and with `[` and `]` the selected spot, as its Size slider does.
    case spot
    /// The Stack workspace's retouch brush.
    case stack
}

/// Sizing brushes from the keyboard and pointer, and panning with Space, in every tool (UX-15).
public extension EditorModel {
    /// A tool draws over the canvas and takes its clicks and drags.
    var hasToolOverlay: Bool {
        guard info != nil, !isShowingOriginal else { return false }
        return [.masking, .crop, .heal].contains(activeTool) || isPlacingGuides
    }

    var sizedBrush: SizedBrush? {
        if let stackWorkspace {
            return stackWorkspace.isRetouching ? .stack : nil
        }
        if isRefiningEdges {
            return .edge
        }
        switch activeTool {
        case .masking: return isBrushing ? .mask : nil
        case .heal: return .spot
        default: return nil
        }
    }

    /// `[` and `]`: a step of the active brush's size, or of its feather with Shift.
    func nudgeSizedBrush(direction: Double, feather: Bool) {
        switch sizedBrush {
        case .mask:
            nudgeBrush(direction: direction, feather: feather)
        case .edge:
            nudgeEdgeBrush(direction: direction)
        case .spot:
            let parameter: ParameterID = feather ? .spotFeather : .spotSize
            let value = spotValue(parameter)
            setSpotValue(parameter, value + direction * (feather ? 10 : max(1, (value * 0.15).rounded())))
        case .stack:
            stackWorkspace?.nudgeBrush(direction: direction, hardness: feather)
        case nil:
            break
        }
    }

    /// ⌘-scroll over the photo: the active brush grows about 15% a notch, or its feather 5 with
    /// Shift. Spots already placed keep their size. Returns whether a brush took it.
    func scrollSizedBrush(by notches: Double, feather: Bool) -> Bool {
        guard let brush = sizedBrush else { return false }
        let growth = pow(1.15, notches)
        switch brush {
        case .mask where feather:
            brushes[activeBrush][.maskBrushFeather] += notches * 5
        case .mask:
            brushes[activeBrush][.maskBrushSize] *= growth
        case .edge:
            edgeBrushSize = ParameterID.maskBrushSize.spec.clamp(edgeBrushSize * growth)
        case .spot where feather:
            spotSettings[.spotFeather] += notches * 5
        case .spot:
            spotSettings[.spotSize] *= growth
        case .stack:
            stackWorkspace?.scrollBrush(by: notches, hardness: feather)
        }
        return true
    }

    /// Space pressed while a tool draws over the canvas.
    func beginSpacePan() {
        isSpacePanning = true
        spacePanUsed = false
    }

    /// The photo was clicked or dragged, which with Space held pans or zooms it.
    func noteSpacePanUse() {
        if isSpacePanning {
            spacePanUsed = true
        }
    }

    /// Space let go: a press with no click or drag toggles the zoom, as Space does without a tool.
    func endSpacePan() {
        guard isSpacePanning else { return }
        isSpacePanning = false
        if !spacePanUsed {
            perform(.toggleZoom)
        }
    }

    /// The window lost the keyboard with Space held, so its release won't arrive.
    func cancelSpacePan() {
        isSpacePanning = false
    }
}
