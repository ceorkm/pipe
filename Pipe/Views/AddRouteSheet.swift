import SwiftUI
import PipeCore

/// Choose app, choose proxy, turn it on. One sheet, two panes, no wizard.
struct AddRouteSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedApp: InstalledApp?
    @State private var selectedProxy: ProxyProfile?
    @State private var killSwitch = true
    @State private var showProxyEditor = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                appPane.frame(width: 320)
                Divider()
                proxyPane
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 480)
        .onAppear {
            searchFocused = true
            if selectedProxy == nil, model.config.proxies.count == 1 { selectedProxy = model.config.proxies.first }
        }
        .sheet(isPresented: $showProxyEditor) {
            ProxyEditorSheet(profile: nil) { saved in selectedProxy = saved }
        }
    }

    // MARK: Apps

    private var filteredApps: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return model.installedApps }
        return model.installedApps.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
    }

    private var recentApps: [InstalledApp] {
        model.recentAppIDs.compactMap { id in model.installedApps.first { $0.bundleID == id } }
    }

    private var appPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneHeader(title: "1. Choose an app", buttonTitle: "Other…", action: pickAppManually)
            SearchField(text: $search).focused($searchFocused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    if search.isEmpty, !recentApps.isEmpty {
                        SectionLabel("Recently used")
                        ForEach(recentApps) { appRow($0) }
                        SectionLabel("All applications").padding(.top, 8)
                    }
                    ForEach(filteredApps) { appRow($0) }
                    if filteredApps.isEmpty {
                        Text("No app matches “\(search)”").font(.callout).foregroundStyle(.secondary).padding(.top, 20).frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 16).padding(.top, 16)
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let selected = selectedApp == app
        let routed = model.route(forApp: app.bundleID) != nil
        return HStack(spacing: 10) {
            AppIconView(app: app, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.callout)
                Text(app.bundleID).font(.caption2).foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.7)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if routed {
                Text("Routed").font(.caption2.weight(.medium)).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selectedApp = app }
    }

    // MARK: Proxies

    private var proxyPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneHeader(title: "2. Choose a proxy", buttonTitle: "Add Proxy…") { showProxyEditor = true }
            if model.config.proxies.isEmpty {
                EmptyStateView(symbol: "globe", title: "No proxies yet", message: "Add a SOCKS5 or HTTP proxy first.") {
                    Button("Add Proxy…") { showProxyEditor = true }
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.config.proxies) { proxyRow($0) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 16)
    }

    private func proxyRow(_ proxy: ProxyProfile) -> some View {
        let selected = selectedProxy == proxy
        let result = model.testResults[proxy.id]
        return HStack(spacing: 12) {
            FlagView(countryCode: result?.countryCode, size: 30).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(proxy.name).font(.callout.weight(.semibold))
                Text("\(proxy.proto.displayName) · \(proxy.host):\(String(proxy.port))").font(.caption).foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
            }
            Spacer()
            if let country = result?.country {
                Text(country).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white) }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(selected ? 0 : 0.08), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { selectedProxy = proxy }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $killSwitch) {
                Text("Block this app if the proxy disconnects").font(.callout)
            }
            .toggleStyle(.switch).controlSize(.small)
            .help("On: the app gets no internet at all when the proxy is down. Off: it falls back to your normal connection.")
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            PrimaryButton(action: turnOn) { Text("Turn On").frame(minWidth: 64) }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedApp == nil || selectedProxy == nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func turnOn() {
        guard let app = selectedApp, let proxy = selectedProxy else { return }
        model.addRoute(app: app, proxy: proxy, killSwitch: killSwitch)
        dismiss()
    }

    private func pickAppManually() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let app = model.addAppManually(url) {
            selectedApp = app
            search = ""
        }
    }
}

// MARK: - Pieces

private struct PaneHeader: View {
    var title: String
    var buttonTitle: String
    var action: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button(buttonTitle, action: action).controlSize(.small)
        }
    }
}

private struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).kerning(0.6)
            .padding(.horizontal, 8).padding(.bottom, 2)
    }
}

/// Rounded search field that looks like the one in Finder's sidebar, not a form text field.
struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}
