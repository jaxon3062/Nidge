import SwiftUI

@main
struct NidgeApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarded") private var onboarded = false

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                GridView()
            }
            .environment(model)
            .fullScreenCover(isPresented: .constant(!onboarded)) {
                OnboardingView { onboarded = true }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Foreground only until M3 adds background downloads.
                if phase == .active, onboarded { model.start() } else if phase == .background { model.stop() }
            }
            .onChange(of: onboarded) { _, done in
                if done { model.start() }
            }
        }
    }
}
