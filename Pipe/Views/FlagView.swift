import SwiftUI
import AppKit

/// Country flag for a two-letter ISO code, from the bundled SVG set (public domain, hampusborgos/country-flags).
/// Falls back to a globe when the code is unknown or the proxy has not been tested yet.
struct FlagView: View {
    var countryCode: String?
    var size: CGFloat = 28

    var body: some View {
        if let image = Self.image(for: countryCode) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(4 / 3, contentMode: .fill)
                .frame(width: size, height: size * 0.75)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        } else {
            Image(systemName: "globe").font(.system(size: size * 0.7)).foregroundStyle(.secondary).frame(width: size, height: size * 0.75)
        }
    }

    private static var cache: [String: NSImage] = [:]

    static func image(for code: String?) -> NSImage? {
        guard let code = code?.lowercased(), code.count == 2 else { return nil }
        if let cached = cache[code] { return cached }
        guard let url = Bundle.main.url(forResource: code, withExtension: "svg", subdirectory: "Flags"), let img = NSImage(contentsOf: url) else { return nil }
        cache[code] = img
        return img
    }
}
