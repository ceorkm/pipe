<p align="center">
  <img src=".github/icon.png" width="128" alt="Pipe">
</p>

<h1 align="center">Pipe</h1>

<p align="center">Route one Mac app through a proxy. Leave everything else alone.</p>

You might want Meta AI to come out of a US address while Safari, Mail and everything else keep using your normal connection. Pipe does that. The app you pick doesn't need to support proxies, and nothing about the rest of your Mac changes.

<p align="center">
  <a href="https://github.com/ceorkm/pipe/releases/latest"><b>Download for macOS</b></a>
</p>

Requires macOS 15 or later. The download is signed and notarized by Apple. Move Pipe to your Applications folder before opening it, since macOS only installs network extensions from there.

## How it works

Pipe installs a network extension that macOS hands every outgoing connection to, along with the identity of the app that opened it. For each connection Pipe answers one question: does this belong to an app I have a route for?

If not, Pipe declines it and the connection carries on untouched. That refusal is handled by macOS, not by Pipe's code, which is why unrouted apps are genuinely unaffected rather than merely intended to be.

If it does, Pipe opens a connection to the proxy you chose, speaks SOCKS5 or HTTP CONNECT to it, and relays the bytes.

Pipe is not a VPN and does not change your system proxy settings, your Wi-Fi settings, or any app's preferences.

## Kill switch

Each route has a setting called *Block this app if the proxy disconnects*.

Leave it on and the app gets nothing when the proxy is unreachable. Its connections are refused. It never quietly falls back to your real address, which is the whole point of routing it in the first place.

Turn it off and Pipe relays the app's traffic directly while the proxy is down, and says so plainly in the interface: *Direct, proxy unreachable*, in orange. There is no state where Pipe silently stops doing what you asked.

Proxy health is tracked per proxy rather than per connection. The first failure marks it down and a single background probe retries every few seconds, so a dead proxy produces immediate answers instead of a queue of timeouts.

## Apps with helper processes

Chrome, Discord, Slack, VS Code and anything else built on Chromium or Electron split their networking across helper processes that carry different identities from the app you actually picked. Pipe matches those helpers three ways: the exact bundle identifier, any identifier namespaced beneath it, and any executable living inside the app bundle you chose. Process IDs are never used as identity, since macOS reuses them.

## What Pipe does not do

It does not read your traffic, decrypt HTTPS, or install certificates. It sees which app a connection belongs to and where that connection is going, because routing is impossible without knowing those two things, and nothing more. Connection counts stay on your Mac. Proxy passwords go in your Keychain, never into a settings file.

## Known limits

**System DNS.** When an app connects by hostname, macOS resolves the name through its own resolver before Pipe ever sees the connection, and that lookup is not attributable to the app. Pipe hands the hostname to the proxy so the connection itself does not depend on the local answer, but the fact that the name was looked up is visible on your network. Closing that gap requires a DNS proxy, which has not been built or tested here, so Pipe does not claim to prevent it.

**UDP.** SOCKS5 proxies can carry UDP and Pipe uses that. HTTP proxies cannot. When a routed app sends UDP through an HTTP proxy, Pipe blocks it rather than letting it escape directly, and Chromium-based apps fall back from QUIC to TCP on their own.

**IPv6.** Both families are routed. A proxy that cannot reach IPv6 destinations causes those connections to fail rather than leak.

## Building

```bash
brew install xcodegen
xcodegen generate
open Pipe.xcodeproj
```

The bundle identifiers and team id in `project.yml` are mine. Change `DEVELOPMENT_TEAM`, `bundleIdPrefix` and the two `PRODUCT_BUNDLE_IDENTIFIER` values to your own, and match them in `PipeIdentifiers` and the release entitlements.

Pipe is distributed with Developer ID and notarization, not through the App Store. A transparent proxy extension can ship either way, but the App Store build would have to be sandboxed, which costs the ability to pick an app from anywhere on disk and gains nothing for routing.

System extensions only install from `/Applications` and only when notarized, so a development build cannot activate the extension. A working build has to be archived, signed with Developer ID, notarized, stapled and copied to `/Applications`.

That needs Developer ID provisioning profiles carrying the Network Extension capability, and a `notarytool` keychain profile. Xcode cannot emit the `-systemextension` entitlement variant on its own, so the app and the extension have to be signed manually with their release entitlements after the archive.

## Testing

Unit tests cover the proxy protocols against in-process servers, including wrong passwords, refused connections and unreachable hosts:

```bash
cd PipeCore && swift test
```

Routing is verified by running a test app under a route and comparing what it sees against your real address across IPv4, IPv6, UDP, QUIC, WebSockets and DNS, so any protocol that escapes is named rather than missed.

A real run confirmed all of it: routed apps saw the proxy's address while an unrouted request saw the Mac's, two apps routed through two different proxies at once, Chromium and Electron helpers were attributed correctly, the kill switch blocked rather than leaked, and routing survived quitting the app.

## Layout

| Path | What it is |
| --- | --- |
| `Pipe/` | The app: SwiftUI interface and menu bar |
| `PipeExtension/` | The network extension that does the routing |
| `PipeCore/` | Shared code: SOCKS5, HTTP CONNECT, models, tests |
| `Probe/` | Test app used to check for leaks |

## Licence

MIT. See [LICENSE](LICENSE).
