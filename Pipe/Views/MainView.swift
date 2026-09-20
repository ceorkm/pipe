import SwiftUI
import PipeCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case routes, proxies, activity
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .routes: return "arrow.triangle.branch"
        case .proxies: return "globe"
        case .activity: return "waveform.path.ecg"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem = .routes
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @State private var showAdd = false

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar
                    .frame(width: 200)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.22), value: sidebarVisible)
        .navigationTitle(selection.title)
        // One toolbar for the whole window, with stable ids, so switching screens or toggling the
        // sidebar never rebuilds the buttons (rebuilding is what makes them flash).
        .toolbar(id: "main") {
            ToolbarItem(id: "sidebar", placement: .navigation) {
                Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.leading") }
                    .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            // Activity has nothing to add, so the item is left out entirely. Hiding it with
            // opacity still draws the toolbar's glass capsule, which reads as an empty button.
            if selection != .activity {
                ToolbarItem(id: "add", placement: .primaryAction) {
                    Button { showAdd = true } label: { Label(selection == .proxies ? "Add Proxy" : "Add Route", systemImage: "plus") }
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            if selection == .proxies { ProxyEditorSheet(profile: nil) { _ in } } else { AddRouteSheet() }
        }
        .sheet(isPresented: .constant(!model.hasCompletedSetup)) {
            OnboardingView()
        }
    }

    /// Own sidebar: shaded column, rows with the accent selection, Settings pinned at the bottom.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarItem.allCases) { item in
                sidebarRow(item.title, symbol: item.symbol, selected: selection == item) { selection = item }
            }
            Spacer()
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.045))
    }

    private func sidebarRow(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(selected ? Color.white : Color.accentColor)
        }
        .fontWeight(selected ? .semibold : .regular)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .routes: RoutesView(showAdd: $showAdd)
        case .proxies: ProxiesView(showAdd: $showAdd)
        case .activity: ActivityView()
        }
    }
}

// MARK: - Shared pieces

struct RouteStatePresentation {
    enum Tone { case ok, bad, warn, off, pending }
    var text: String
    var tone: Tone
    var detail: String?

    var color: Color {
        switch tone {
        case .ok: return .green
        case .bad: return .red
        case .warn, .pending: return .orange
        case .off: return .secondary
        }
    }

    static func describe(route: Route, status: RouteStatus?, tunnelRunning: Bool) -> RouteStatePresentation {
        guard route.isEnabled else { return .init(text: "Off", tone: .off) }
        guard tunnelRunning, let status else { return .init(text: "Starting", tone: .pending) }
        switch status.state {
        case .idle: return .init(text: "Ready", tone: .ok)
        case .connected: return .init(text: "Connected", tone: .ok)
        case .blocked: return .init(text: "Blocked · proxy unreachable", tone: .bad, detail: status.lastError)
        case .fallbackDirect: return .init(text: "Direct · proxy unreachable", tone: .warn, detail: status.lastError)
        case .missingCredential: return .init(text: "Waiting for password", tone: .pending)
        }
    }
}

/// Small colored capsule, as in the mockup.
struct StatusPill: View {
    var state: RouteStatePresentation
    var body: some View {
        Text(state.text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(state.tone == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(state.color))
            .background(Capsule().fill(state.color.opacity(state.tone == .off ? 0.10 : 0.16)))
            .overlay(Capsule().strokeBorder(state.color.opacity(0.35), lineWidth: 0.5))
            .help(state.detail ?? "")
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.8), radius: 4)
    }
}

/// Flat content card (no glass on content, per the macOS 27 guidance).
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

struct AppIconView: View {
    var app: InstalledApp?
    var size: CGFloat = 32
    var body: some View {
        if let app {
            Image(nsImage: app.icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.7)).frame(width: size, height: size).foregroundStyle(.secondary)
        }
    }
}

struct EmptyStateView<Actions: View>: View {
    var symbol: String
    var title: String
    var message: String
    @ViewBuilder var actions: Actions

    init(symbol: String, title: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol; self.title = title; self.message = message; self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            actions.padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Primary action button: glass on macOS 26+, prominent bordered before.
struct PrimaryButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: Label
    var body: some View {
        if #available(macOS 26, *) {
            Button(action: action) { label }.buttonStyle(.glassProminent)
        } else {
            Button(action: action) { label }.buttonStyle(.borderedProminent)
        }
    }
}

/// ByteCountFormatter renders 0 as "Zero KB", which reads like a fault. Show a plain dash.
func formatBytes(_ n: UInt64) -> String {
    guard n > 0 else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
}
