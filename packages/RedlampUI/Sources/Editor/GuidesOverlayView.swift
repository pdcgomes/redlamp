import AppKit
import RedlampEngineAPI
import SwiftUI

/// Guided Upright's guides over the canvas: drag along an edge that should be vertical or
/// horizontal to add one (up to four). They are kept in the photo's coordinates, so they stay
/// on their edges as the correction applies.
struct GuidesOverlayView: View {
    @Environment(EditorModel.self) private var model
    @State private var drawing: (start: CGPoint, end: CGPoint)?

    var body: some View {
        GeometryReader { geometry in
            let frame = ImageFrame(rect: model.canvas.imageRect(in: geometry.size), geometry: model.canvasGeometry)
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(drawGesture(frame))
                    .onHover { inside in
                        if inside {
                            NSCursor.crosshair.push()
                        } else {
                            NSCursor.pop()
                        }
                    }

                Path { path in
                    for guide in model.uprightGuides {
                        path.move(to: frame.view(guide.start))
                        path.addLine(to: frame.view(guide.end))
                    }
                    if let drawing {
                        path.move(to: drawing.start)
                        path.addLine(to: drawing.end)
                    }
                }
                .stroke(Color.yellow, lineWidth: 1.5)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .allowsHitTesting(false)
            }
        }
    }

    private func drawGesture(_ frame: ImageFrame) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { gesture in
                drawing = (gesture.startLocation, gesture.location)
            }
            .onEnded { gesture in
                drawing = nil
                model.addGuide(GuideLine(start: frame.image(gesture.startLocation), end: frame.image(gesture.location)))
            }
    }
}
