import RedlampBench
import SwiftUI

@main
struct BenchApp: App {
    @State private var model = BenchModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
                .task {
                    // `-bench-open <id>` opens a folder at launch, for screenshots.
                    if let index = CommandLine.arguments.firstIndex(of: "-bench-open"),
                       index + 1 < CommandLine.arguments.count {
                        model.opened = CommandLine.arguments[index + 1]
                    }
                    model.startWatching()
                    await model.refresh()
                }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        await model.refreshIfStale()
                    }
                }
        }
        .onChange(of: phase) { _, phase in
            switch phase {
            case .active:
                model.reload()
                model.startWatching()
                Task { await model.refresh() }
            case .background:
                model.stopWatching()
                Task { await model.sendQueued() }
            default:
                break
            }
        }
    }
}
