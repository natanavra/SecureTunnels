# SecureTunnels

SSH tunnels from the macOS menu bar. SecureTunnels replaces the unmaintained Secure Pipes: it runs
`/usr/bin/ssh` for you, keeps the tunnels alive, and imports your existing Secure Pipes connections.

<p align="center">
  <img src="docs/screenshots/menubar.png" width="320" alt="The menu bar popover listing tunnels with status dots and switches">
</p>

<p align="center">
  <img src="docs/screenshots/tunnels.png" width="760" alt="The Tunnels window with the tunnel editor form">
</p>

## What it does

- Lists every tunnel in a menu bar popover with a live status dot and a switch to connect or disconnect.
- Local forwards, remote forwards and SOCKS proxies.
- Per-tunnel SSH host, port, username, identity file, key passphrase and password. Secrets live in the login
  keychain, not on disk.
- Connects selected tunnels when the app starts, and starts the app at login.
- Reconnects after a drop, after the Mac wakes from sleep, and as soon as the network comes back after an
  outage.
- Imports Secure Pipes connections on first launch and on demand from Settings. Passphrases and passwords are
  not carried over because Secure Pipes keeps them in its own keychain items, so enter them once per tunnel.
- Writes a per-tunnel ssh log under `~/Library/Application Support/SecureTunnels/logs`.

Requires macOS 14 or newer.

## Install

There is no notarized download yet, so macOS will refuse to open a copy you received as a zip until you clear
the quarantine flag. Either build it yourself or install a zip from a teammate.

### Build from source

You need Xcode 15 or newer (SwiftPM and XCTest come with it). No Xcode project is involved.

```bash
git clone https://github.com/natanavra/SecureTunnels.git
cd SecureTunnels
make install
```

`make install` compiles the release build, assembles `build/SecureTunnels.app`, ad-hoc signs it, copies it to
`/Applications` and launches it. The lock icon appears in the menu bar.

### Install from a zip

```bash
unzip SecureTunnels-0.1.0.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/SecureTunnels.app
open /Applications/SecureTunnels.app
```

Without the `xattr` line Gatekeeper reports that the app is damaged or from an unidentified developer. The app
is ad-hoc signed because there is no Apple Developer ID behind it. Right-clicking the app and choosing Open
works too.

### First run

1. If Secure Pipes is installed, its connections are imported automatically. Otherwise open Manage Tunnels
   from the menu bar and press + to add one.
2. Open each tunnel and enter its key passphrase or password if it needs one.
3. Turn on "Launch SecureTunnels at login" in Settings. The app has to run from `/Applications` for macOS to
   accept it as a login item.
4. Quit Secure Pipes before connecting, otherwise the local ports are still taken.

## Build targets

| Target             | What it does                                                        |
| ------------------ | ------------------------------------------------------------------- |
| `make build`       | Release build into `build/SecureTunnels.app`                        |
| `make debug`       | Same, debug configuration                                           |
| `make run`         | Build and open the app from the build folder                        |
| `make install`     | Build, copy to `/Applications` and launch                           |
| `make dist`        | Build and zip the app as `build/SecureTunnels-<version>.zip`        |
| `make test`        | Run the unit tests (`swift test`)                                   |
| `make screenshots` | Render the README screenshots with sample data, light and dark      |
| `make icon`        | Regenerate `Resources/AppIcon.icns` from `Resources/icon-source.png` |

Set `VERSION=0.2.0` to stamp a different version, and `CODESIGN_IDENTITY="Developer ID Application: ..."` to
sign with a real identity. With ad-hoc signing every rebuild is a new code identity, so macOS may ask once per
tunnel to allow the new build to read the stored secret. Choose "Always Allow", or sign with a stable identity.

The app also answers two command line flags, which the Makefile uses:

```bash
/Applications/SecureTunnels.app/Contents/MacOS/SecureTunnels --launch-at-login on|off|status
/Applications/SecureTunnels.app/Contents/MacOS/SecureTunnels --snapshot <dir> [--demo] [--dark]
```

## How a tunnel runs

Each tunnel is one `ssh -N` process with `ExitOnForwardFailure`, keep-alives and an app-owned `known_hosts`
file. The app treats the tunnel as connected when ssh's `LocalCommand` prints a marker, which is the only
reliable signal with `-N`.

Key passphrases and passwords are answered through `SSH_ASKPASS`. The app writes them to ssh's stdin as JSON
and the bundled `SecureTunnelsAskPass` helper reads them back when ssh asks. They never appear in arguments or
environment variables. Host keys of new servers are trusted on first connect (`accept-new`) unless strict
checking is enabled for the tunnel. A changed host key is always rejected.

When ssh exits while the tunnel should be up, the app waits the tunnel's reconnect interval and starts it
again. When the network path goes away it kills the sessions immediately and relaunches them the moment a
route is back. Before sleep it does the same and reconnects three seconds after wake.

## Layout

- `Sources/SecureTunnelsCore`: model, JSON storage, keychain, ssh argument builder, Secure Pipes importer.
- `Sources/SecureTunnels`: the SwiftUI app (menu bar popover, Tunnels window, Settings, tunnel manager).
- `Sources/SecureTunnelsAskPass`: the askpass helper.
- `Tests/SecureTunnelsCoreTests`: unit tests with a Secure Pipes fixture.
- `scripts/bundle.sh`: turns the SwiftPM products into an app bundle.

Data lives in `~/Library/Application Support/SecureTunnels/` (`tunnels.json`, `known_hosts`, `logs/`).

## License

MIT. See `LICENSE`.
