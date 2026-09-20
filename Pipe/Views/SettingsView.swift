import SwiftUI
import PipeCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var message: String?
    @State private var busy = false
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("General") {
                    settingRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch Pipe at login")
                            Text("Keeps routes and kill switches active after a restart. Without this, routes resume the next time you open Pipe.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Toggle("", isOn: $model.launchAtLogin).toggleStyle(.switch).labelsHidden()
                    }
                }

                section("Network Extension") {
                    settingRow {
                        Label {
                            Text("Extension")
                        } icon: {
                            Image(systemName: extensionSymbol).foregroundStyle(extensionColor)
                        }
                        Spacer()
                        Text(extensionText).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    rowDivider
                    settingRow {
                        Label {
                            Text("Routing")
                        } icon: {
                            Image(systemName: model.tunnel.isRunning ? "checkmark.circle.fill" : "pause.circle.fill")
                                .foregroundStyle(model.tunnel.isRunning ? Color.green : Color.secondary)
                        }
                        Spacer()
                        Text(model.tunnel.isRunning ? "Active" : "Inactive").foregroundStyle(.secondary)
                    }
                    rowDivider
                    settingRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reinstall extension")
                            Text("Use this if routing stops working after a macOS update.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Button("Reinstall") { reinstall() }.disabled(busy)
                    }
                    rowDivider
                    settingRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remove proxy configuration").foregroundStyle(.red)
                            Text("Deletes Pipe's entry from macOS network settings. Your proxies and routes are kept.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Button("Remove") { confirmRemove = true }.disabled(busy)
                    }
                }

                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                section("Privacy") {
                    VStack(alignment: .leading, spacing: 10) {
                        privacyLine("eye.slash", "Pipe never reads your traffic. It sees which app a connection belongs to and where it is going, nothing else.")
                        privacyLine("lock", "No HTTPS is decrypted and no certificates are installed.")
                        privacyLine("key", "Proxy passwords are stored in your Keychain, never in a settings file.")
                        privacyLine("desktopcomputer", "Connection counts stay on this Mac. Nothing is sent anywhere.")
                    }
                    .padding(14)
                }

                HStack {
                    Spacer()
                    Text("Pipe \(version)").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 600)
        .alert("Remove proxy configuration?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { removeConfiguration() }
        } message: {
            Text("Routing stops until you set Pipe up again. Your proxies and routes are kept.")
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).kerning(0.6)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    private func settingRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Divider().opacity(0.5).padding(.leading, 14)
    }

    private func privacyLine(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: State

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var extensionText: String {
        switch model.installer.state {
        case .installed: return "Installed"
        case .installing: return "Installing"
        case .needsApproval: return "Waiting for approval in System Settings"
        case .failed(let e): return e
        case .unknown: return model.tunnel.isRunning ? "Installed" : (model.hasCompletedSetup ? "Installed" : "Not installed")
        }
    }

    private var extensionSymbol: String {
        switch model.installer.state {
        case .failed: return "exclamationmark.triangle.fill"
        case .needsApproval: return "exclamationmark.circle.fill"
        default: return model.hasCompletedSetup ? "checkmark.circle.fill" : "circle.dashed"
        }
    }

    private var extensionColor: Color {
        switch model.installer.state {
        case .failed: return .red
        case .needsApproval: return .orange
        default: return model.hasCompletedSetup ? .green : .secondary
        }
    }

    private func reinstall() {
        busy = true; message = nil
        Task {
            do {
                try await model.installer.activate()
                await model.sync()
                message = "Extension reinstalled."
            } catch {
                message = ExtensionInstaller.describe(error)
            }
            busy = false
        }
    }

    private func removeConfiguration() {
        busy = true; message = nil
        Task {
            do {
                try await model.tunnel.removeConfiguration()
                model.hasCompletedSetup = false
                message = "Removed. Pipe will ask to set up again next time you open it."
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }
}
