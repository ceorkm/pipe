import SwiftUI
import PipeCore

@main
struct PipeApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Pipe", id: "main") {
            MainView()
                .fontDesign(.rounded)
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
                .task { await model.start() }
                .onAppear { model.isWindowVisible = true }
                .onDisappear { model.isWindowVisible = false }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 560)

        MenuBarExtra {
            MenuBarView().fontDesign(.rounded).environmentObject(model)
        } label: {
            Image(systemName: model.enabledRoutes.isEmpty ? "point.3.connected.trianglepath.dotted" : "point.3.filled.connected.trianglepath.dotted")
        }

        Settings {
            SettingsView().fontDesign(.rounded).environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window keeps routing alive: Pipe lives in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }
}

func openMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
        window.makeKeyAndOrderFront(nil)
    } else {
        NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
    }
}
