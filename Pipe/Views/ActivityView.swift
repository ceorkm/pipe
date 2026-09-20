import SwiftUI
import PipeCore

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    private struct Row: Identifiable {
        let route: Route
        let proxy: ProxyProfile?
        let state: RouteStatePresentation
        let status: RouteStatus?
        var id: UUID { route.id }
    }

    private var rows: [Row] {
        model.enabledRoutes.map { r in
            Row(route: r,
                proxy: model.config.proxy(for: r),
                state: RouteStatePresentation.describe(route: r, status: model.statuses[r.id], tunnelRunning: model.tunnel.isRunning),
                status: model.statuses[r.id])
        }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                EmptyStateView(symbol: "waveform.path.ecg", title: "Nothing routed",
                               message: "Turn on a route to watch its connections here.")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        totals
                        ForEach(rows) { row in
                            card(row)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: Summary

    private var totals: some View {
        let up = rows.reduce(UInt64(0)) { $0 + ($1.status?.bytesUp ?? 0) }
        let down = rows.reduce(UInt64(0)) { $0 + ($1.status?.bytesDown ?? 0) }
        let live = rows.reduce(0) { $0 + ($1.status?.activeConnections ?? 0) }
        return HStack(spacing: 10) {
            StatusDot(color: live > 0 ? .green : .secondary)
            Text(live == 0 ? "Idle" : "\(live) live \(live == 1 ? "connection" : "connections")").fontWeight(.semibold)
            Spacer()
            Label(formatBytes(up), systemImage: "arrow.up")
            Label(formatBytes(down), systemImage: "arrow.down")
                .padding(.leading, 6)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.bottom, 4)
    }

    // MARK: Per-route card

    private func card(_ row: Row) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                AppIconView(app: model.installedApp(for: row.route), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.route.appName).font(.headline)
                    HStack(spacing: 4) {
                        Text("via").foregroundStyle(.secondary)
                        Text(row.proxy?.name ?? "Missing proxy")
                        if let cc = row.proxy.flatMap({ model.testResults[$0.id]?.countryCode }) {
                            FlagView(countryCode: cc, size: 18).padding(.leading, 2)
                        }
                    }
                    .font(.subheadline)
                }
                Spacer()
                StatusPill(state: row.state)
            }
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                stat("Connections", value: String(row.status?.activeConnections ?? 0),
                     symbol: "point.3.connected.trianglepath.dotted",
                     highlight: (row.status?.activeConnections ?? 0) > 0)
                statDivider
                stat("Upload", value: formatBytes(row.status?.bytesUp ?? 0), symbol: "arrow.up")
                statDivider
                stat("Download", value: formatBytes(row.status?.bytesDown ?? 0), symbol: "arrow.down")
            }
        }
        .card()
        .help(row.state.detail ?? "")
    }

    private func stat(_ title: String, value: String, symbol: String, highlight: Bool = false) -> some View {
        VStack(spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(highlight ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
                .animation(.default, value: value)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 28)
    }
}
