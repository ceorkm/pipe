import Foundation
import SystemExtensions
import PipeCore

/// Activates the bundled system extension. One request at a time; never re-prompts on its own.
@MainActor
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case unknown
        case installing
        case needsApproval
        case installed
        case failed(String)
    }

    @Published private(set) var state: State = .unknown
    private var continuation: CheckedContinuation<Void, Error>?

    func activate() async throws {
        if state == .installing { return }
        state = .installing
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: PipeIdentifiers.extensionBundleID, queue: .main)
        request.delegate = self
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    // MARK: OSSystemExtensionRequestDelegate

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.state = .installed
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            let text = Self.describe(error)
            Log.app.error("extension activation failed: \(text, privacy: .public)")
            self.state = .failed(text)
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? OSSystemExtensionError else { return error.localizedDescription }
        switch e.code {
        case .requestCanceled: return "Approval was cancelled."
        case .requestSuperseded: return "A newer request replaced this one."
        case .extensionNotFound: return "The extension is missing from the app bundle."
        case .codeSignatureInvalid: return "The app's code signature or notarization could not be verified."
        case .validationFailed: return "macOS rejected the extension's configuration."
        case .forbiddenBySystemPolicy: return "System policy forbids this extension."
        case .unsupportedParentBundleLocation: return "Pipe has to be in the Applications folder to install its extension. Move it there and reopen it."
        case .authorizationRequired: return "Approval is required in System Settings."
        default: return error.localizedDescription
        }
    }
}
