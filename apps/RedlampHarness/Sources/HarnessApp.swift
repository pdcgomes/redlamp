import SwiftUI

@main
struct HarnessApp: App {
    var body: some Scene {
        WindowGroup("Redlamp Harness") {
            HarnessRootView()
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1400, height: 900)
    }
}
