import SwiftUI
import PipeCore

struct ProxiesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: ProxyProfile?
    @Binding var showAdd: Bool
    @State private var testing: Set<UUID> = []
    @State private var testErrors: [UUID: String] = [:]

    var body: some View {
        Group {
            if model.config.proxies.isEmpty {
                EmptyStateView(symbol: "globe", title: "No proxies yet", message: "Add a SOCKS5 or HTTP proxy to start.") {
                    PrimaryButton(action: { showAdd = true }) { Text("Add Proxy") }
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.config.proxies) { proxy in row(proxy) }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(item: $editing) { p in ProxyEditorSheet(profile: p) { _ in } }
    }

    private func row(_ proxy: ProxyProfile) -> some View {
        let result = model.testResults[proxy.id]
        return HStack(spacing: 14) {
            FlagView(countryCode: result?.countryCode, size: 40).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(proxy.name).font(.headline)
                Text([proxy.proto.displayName, result?.country].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                if testing.contains(proxy.id) {
                    ProgressView().controlSize(.small)
                    Text("Testing").foregroundStyle(.secondary)
                } else if let error = testErrors[proxy.id] {
                    StatusDot(color: .red)
                    Text(error)
                } else if let result {
                    StatusDot(color: .green)
                    Text("\(result.latencyMs) ms")
                } else {
                    StatusDot(color: .secondary)
                    Text("Not tested").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            Button("Test") { test(proxy) }.disabled(testing.contains(proxy.id))
        }
        .card()
        .contentShape(Rectangle())
        .help("\(proxy.host):\(String(proxy.port))" + (proxy.username.map { " · \($0)" } ?? "") + (result?.publicIP.map { " · exit \($0)" } ?? ""))
        .contextMenu {
            Button("Edit…") { editing = proxy }
            Button("Test Connection") { test(proxy) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteProxy(proxy.id) }
        }
        .onTapGesture(count: 2) { editing = proxy }
    }

    private func test(_ proxy: ProxyProfile) {
        testing.insert(proxy.id)
        testErrors[proxy.id] = nil
        Task {
            let r = await model.testProxy(proxy, password: model.password(for: proxy))
            if case .failure(let e) = r { testErrors[proxy.id] = e.localizedDescription }
            testing.remove(proxy.id)
        }
    }
}

struct ProxyEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onSave: (ProxyProfile) -> Void
    @State private var profile: ProxyProfile
    @State private var password: String
    @State private var portText: String
    @State private var testState: TestState = .idle
    @FocusState private var focused: Field?
    private let isNew: Bool

    enum Field { case name, host, port, user, pass }
    enum TestState: Equatable { case idle, running, ok(ProxyTestResult), failed(String) }

    init(profile: ProxyProfile?, onSave: @escaping (ProxyProfile) -> Void) {
        self.onSave = onSave
        isNew = profile == nil
        let p = profile ?? ProxyProfile(name: "", host: "", port: 1080, proto: .socks5)
        _profile = State(initialValue: p)
        _portText = State(initialValue: String(p.port))
        _password = State(initialValue: "")
    }

    private var valid: Bool {
        !profile.name.trimmingCharacters(in: .whitespaces).isEmpty && !profile.host.trimmingCharacters(in: .whitespaces).isEmpty && UInt16(portText).map { $0 > 0 } == true
    }

    private var draft: ProxyProfile {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.host = p.host.trimmingCharacters(in: .whitespaces)
        p.port = UInt16(portText) ?? p.port
        p.username = p.username?.trimmingCharacters(in: .whitespaces).isEmpty == true ? nil : p.username
        return p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Add Proxy" : "Edit Proxy").font(.title2.weight(.bold))
            Text("The password goes into your Keychain. Nothing is saved in plain text.").foregroundStyle(.secondary).font(.callout).padding(.top, 2).padding(.bottom, 18)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    label("Name")
                    TextField("", text: $profile.name, prompt: Text("Name this proxy")).focused($focused, equals: .name)
                }
                GridRow {
                    label("Protocol")
                    Picker("", selection: $profile.proto) {
                        ForEach(ProxyProtocol.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    label("Host")
                    TextField("", text: $profile.host, prompt: Text("Host or IP")).focused($focused, equals: .host)
                }
                GridRow {
                    label("Port")
                    TextField("", text: $portText, prompt: Text("1080")).frame(width: 90).focused($focused, equals: .port)
                }
                GridRow {
                    label("Username")
                    TextField("", text: Binding(get: { profile.username ?? "" }, set: { profile.username = $0 }), prompt: Text("Leave empty if the proxy has no login")).focused($focused, equals: .user)
                }
                GridRow {
                    label("Password")
                    SecureField("", text: $password, prompt: Text(isNew ? "" : "Unchanged")).focused($focused, equals: .pass)
                }
            }
            .textFieldStyle(.roundedBorder)
            if profile.proto != .socks5 {
                Text("HTTP proxies carry only TCP. Pipe blocks UDP for apps on this proxy so nothing leaks.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }
            Spacer()
            HStack(spacing: 8) {
                switch testState {
                case .idle: EmptyView()
                case .running: ProgressView().controlSize(.small); Text("Testing").foregroundStyle(.secondary)
                case .ok(let r):
                    StatusDot(color: .green)
                    (Text("Connected").bold() + Text(" · \(r.latencyMs) ms" + (r.publicIP.map { " · \($0)" } ?? "") + (r.country.map { " · \($0)" } ?? "")))
                case .failed(let text): StatusDot(color: .red); Text(text).bold()
                }
                Spacer()
                Button("Test Connection") { runTest() }.disabled(!valid || testState == .running)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                PrimaryButton(action: save) { Text(isNew ? "Add" : "Save").frame(minWidth: 50) }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
            .font(.callout)
        }
        .padding(22)
        .frame(width: 520, height: 400)
        .onAppear {
            if !isNew { password = model.password(for: profile) ?? "" }
            focused = .name
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).fontWeight(.medium).frame(width: 80, alignment: .trailing)
    }

    private func save() {
        let p = draft
        model.saveProxy(p, password: password)
        onSave(p)
        dismiss()
    }

    private func runTest() {
        testState = .running
        Task {
            switch await model.testProxy(draft, password: password) {
            case .success(let r): testState = .ok(r)
            case .failure(let e): testState = .failed(e.localizedDescription)
            }
        }
    }
}
