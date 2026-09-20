import SwiftUI
import PipeCore

struct RoutesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showAdd: Bool

    var body: some View {
        Group {
            if model.config.routes.isEmpty {
                EmptyStateView(symbol: "arrow.triangle.branch", title: "Nothing routed yet",
                               message: "Pick an app and a proxy. Only that app goes through the proxy. Every other app keeps your normal connection.") {
                    PrimaryButton(action: { showAdd = true }) { Text("Add Route") }
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        summary
                        ForEach(model.config.routes) { route in
                            RouteCard(route: route)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.syncError {
                Text(error).font(.callout).foregroundStyle(.white).padding(10)
                    .background(.red, in: RoundedRectangle(cornerRadius: 8)).padding()
            }
        }
    }

    private var summary: some View {
        let n = model.enabledRoutes.count
        return HStack(spacing: 10) {
            StatusDot(color: n > 0 ? .green : .secondary)
            Text(n == 0 ? "No apps routed" : "\(n) \(n == 1 ? "app" : "apps") routed").fontWeight(.semibold)
            Text("· every other app is direct").foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 6).padding(.bottom, 4)
    }
}

struct RouteCard: View {
    @EnvironmentObject private var model: AppModel
    let route: Route

    var body: some View {
        let proxy = model.config.proxy(for: route)
        let state = RouteStatePresentation.describe(route: route, status: model.statuses[route.id], tunnelRunning: model.tunnel.isRunning)
        HStack(spacing: 14) {
            AppIconView(app: model.installedApp(for: route), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.appName).font(.headline)
                HStack(spacing: 4) {
                    Text("via").foregroundStyle(.secondary)
                    Text(proxy?.name ?? "Missing proxy")
                    if let cc = proxy.flatMap({ model.testResults[$0.id]?.countryCode }) {
                        FlagView(countryCode: cc, size: 18).padding(.leading, 2)
                    }
                }
                .font(.subheadline)
            }
            .opacity(route.isEnabled ? 1 : 0.55)
            Spacer()
            StatusPill(state: state)
            Toggle("", isOn: Binding(get: { route.isEnabled }, set: { model.setRoute(route.id, enabled: $0) }))
                .toggleStyle(.switch).labelsHidden()
        }
        .card()
        .contextMenu {
            Toggle("Block if proxy disconnects", isOn: Binding(get: { route.killSwitch }, set: { var r = route; r.killSwitch = $0; model.updateRoute(r) }))
            Menu("Use Proxy") {
                ForEach(model.config.proxies) { p in
                    Button(p.name) { var r = route; r.proxyID = p.id; model.updateRoute(r) }
                }
            }
            Divider()
            Button("Remove Route", role: .destructive) { model.deleteRoute(route.id) }
        }
    }
}
