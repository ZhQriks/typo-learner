import SwiftUI
import TypoCore

@main
struct TypoLearnerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .tint(.brand)
        } label: {
            Image(systemName: model.menuIcon)
                .accessibilityLabel("Typo Learner")
        }
        .menuBarExtraStyle(.window)

        Window("Typo Learner", id: "dashboard") {
            DashboardView()
                .environment(model)
                .tint(.brand)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
    }
}
