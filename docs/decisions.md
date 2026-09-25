# Decisions

- **2026-09-16 - Native Swift app:** SecureTunnels is a SwiftUI menu bar app built with SwiftPM and a bundling script, not an Electron or web app, because login items, keychain and ssh process control are macOS-native concerns.
- **2026-09-16 - Secrets through askpass stdin:** Key passphrases and passwords are stored in the login keychain and handed to ssh through the bundled askpass helper over stdin, never through arguments or environment variables.
- **2026-09-16 - Secure Pipes IDs are kept:** Imported tunnels keep their Secure Pipes UUID so repeated imports update rather than duplicate.
- **2026-09-16 - Profiles own shared credentials:** Server settings and secrets shared by several tunnels live in a profile referenced by id; a tunnel without a profile keeps its own, and removing a profile copies its settings back into its tunnels.
- **2026-09-16 - Cloudflare Tunnels through the API, not cloudflared login:** Named tunnels, ingress and DNS records are managed with a user API token via the Cloudflare v4 API and run with `cloudflared tunnel run` plus TUNNEL_TOKEN; the browser-based `cloudflared tunnel login` and cert.pem flow is not used.
- **2026-09-25 - AppKit owns the status item, popover and main window:** SwiftUI is used only for view content hosted in NSHostingController; MenuBarExtra and SwiftUI scenes are not used.
