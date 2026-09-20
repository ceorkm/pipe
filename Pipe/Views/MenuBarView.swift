import SwiftUI
import PipeCore

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let on = model.enabledRoutes
        Text(on.isEmpty ? "No apps routed" : "\(on.count) \(on.count == 1 ? "app" : "apps") routed")
        if !model.config.routes.isEmpty {
            Divider()
            ForEach(model.config.routes) { route in
                let proxy = model.config.proxy(for: route)?.name ?? "Missing proxy"
                let state = RouteStatePresentation.describe(route: route, status: model.statuses[route.id], tunnelRunning: model.tunnel.isRunning)
                Toggle(isOn: Binding(get: { route.isEnabled }, set: { model.setRoute(route.id, enabled: $0) })) {
                    Text("\(route.appName) \u{2192} \(proxy)" + (route.isEnabled && state.color != .green ? "  (\(state.text))" : ""))
                }
            }
            Divider()
            if on.isEmpty {
                Button("Enable All Routes") { model.setAllRoutes(enabled: true) }
            } else {
                Button("Disable All Routes") { model.setAllRoutes(enabled: false) }
            }
        }
        Divider()
        Button("Open Pipe") { openMainWindow() }.keyboardShortcut("o")
        Button("Quit Pipe") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
