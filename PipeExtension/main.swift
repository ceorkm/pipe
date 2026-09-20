import Foundation
import NetworkExtension

// System extension entry point: hand control to NetworkExtension, which instantiates the
// provider class named in Info.plist (NEProviderClasses) when the proxy configuration starts.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
