import SwiftUI

@main
struct MixetteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var mixer: Mixer

    init() {
        let m = Mixer()
        _mixer = StateObject(wrappedValue: m)
        AppDelegate.mixer = m
        Snapshot.runIfRequested(mixer: m)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(mixer)
                .onAppear { mixer.panelVisible = true }
                .onDisappear { mixer.panelVisible = false }
        } label: {
            MenuBarLabel(mixer: mixer)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var mixer: Mixer
    var body: some View {
        // Icône pleine dès qu'au moins une app est réglée : on voit que Mixette agit.
        let active = mixer.apps.contains { !mixer.settings(for: $0).isDefault }
        Image(systemName: active ? "slider.vertical.3" : "slider.horizontal.3")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var mixer: Mixer?

    func applicationWillTerminate(_ notification: Notification) {
        // Arrêt propre : chaque app retrouve son son d'origine immédiatement.
        MainActor.assumeIsolated { AppDelegate.mixer?.shutdown() }
    }
}
