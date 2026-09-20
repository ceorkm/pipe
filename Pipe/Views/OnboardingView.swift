import SwiftUI
import AppKit
import PipeCore

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page = 0
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Group {
            if page == 0 { welcome } else { permissions }
        }
        .frame(width: 640, height: 460)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8).padding(.bottom, 18)
            Text("Welcome to Pipe").font(.system(size: 30, weight: .bold)).padding(.bottom, 8)
            Text("Send one app through a proxy. Everything else on your Mac keeps its normal connection.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440).padding(.bottom, 32)
            HStack(alignment: .top, spacing: 18) {
                point("globe", "Add a proxy", "SOCKS5 or HTTP. Password stays in your Keychain.")
                point("macwindow", "Pick an app", "Claude, Spotify, Telegram, anything installed.")
                point("switch.2", "Turn it on", "Quit and reopen the app, sleep, reboot. Still routed.")
            }
            .padding(.bottom, 36)
            PrimaryButton(action: { page = 1 }) { Text("Continue").frame(minWidth: 90) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 190, alignment: .leading)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("One-time setup").font(.title.weight(.bold)).padding(.bottom, 6)
            Text("Pipe works underneath apps, so macOS needs your permission twice. It only ever sees which app a connection belongs to and where it is going. It never reads content or decrypts anything.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 16)
            step(1, "Allow the network extension", "System Settings › General › Login Items & Extensions › Network Extensions › Pipe") {
                if model.installer.state == .needsApproval {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                }
            }
            Divider()
            step(2, "Allow the proxy configuration", "macOS shows a dialog. Click Allow.") { EmptyView() }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.top, 12).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack {
                Button("Back") { page = 0 }.disabled(busy)
                Spacer()
                PrimaryButton(action: install) {
                    if busy { ProgressView().controlSize(.small).frame(minWidth: 110) } else { Text("Install Extension").frame(minWidth: 110) }
                }
                .keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(32)
    }

    private func step<A: View>(_ n: Int, _ title: String, _ text: String, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(n)).font(.caption.weight(.bold)).foregroundStyle(.white).frame(width: 22, height: 22).background(Circle().fill(.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action().controlSize(.small)
        }
        .padding(.vertical, 12)
    }

    private func install() {
        busy = true; error = nil
        Task {
            do { try await model.completeSetup() } catch { self.error = ExtensionInstaller.describe(error) }
            busy = false
        }
    }
}
