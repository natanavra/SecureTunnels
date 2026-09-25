# Project learnings

## Secure Pipes storage (2026-09-16)

- Connections live in `~/Library/Preferences/net.edgeservices.connections.plist`, not in the app support folder.
  Top-level keys are groups ("Local Forwards", "Remote Forwards", "SOCKS Proxies") with `type` 100 and a
  `children` dictionary keyed by connection name. Children carry `config` and an integer `type`: 1 local
  forward, 2 remote forward, 3 SOCKS proxy, 9 managed SOCKS proxy.
- Numbers are stored inconsistently: ports are strings, intervals are integers, flags are a mix of booleans
  and integers. The importer normalises all of them.
- Remote forwards use `remoteBindAddress`/`remoteBindPort` for the server side and `localBindAddress`/
  `localBindPort` for the local target.
- `~/Library/Application Support/Secure Pipes/` only holds generated `ssh_config`, `known_hosts` and log files
  per connection UUID. Secure Pipes drove ssh through an `expect` script (`ssh_manager.exp`) and detected a
  live session with `PermitLocalCommand yes` + `LocalCommand echo Connected`. SecureTunnels reuses that trick.
- Secrets sit in Secure Pipes' own keychain items and are not imported.

## ssh details

- `ssh -N` prints nothing on success, so `LocalCommand` is the connected signal.
- `SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4+) makes ssh use the askpass helper even though the app has no tty.
  The helper receives only the prompt text as argv; it inherits ssh's stdin, which is how the app passes secrets.
- `StrictHostKeyChecking=accept-new` avoids the yes/no prompt for new hosts and still rejects changed keys.
- `swift build --product A --product B` only builds the last product named; build the whole package instead.

## Reconnect behaviour (2026-09-16)

- `NWPathMonitor` drives the fast path: on an unsatisfied path the manager kills the ssh sessions and shows
  "Waiting for network", and relaunches them as soon as the path is satisfied again. Keep-alives
  (`ServerAliveInterval` x `ServerAliveCountMax`, 30 s x 5 for imported tunnels) still catch dead sessions the
  monitor cannot see, such as a NAT timeout on a healthy network, and then the reconnect interval applies.
- `SMAppService.mainApp.register()` works for the ad-hoc signed bundle once it runs from `/Applications`.
  `sfltool dumpbtm` shows it as `2.com.natanavra.SecureTunnels` with disposition `[enabled, allowed, notified]`.
  From the build folder the status is `notFound`.
- `open` occasionally returns `_LSOpenURLsWithCompletionHandler() failed with error -600` right after `pkill`
  in `make install`; running `open` again works.

## Profiles, groups and conflicts (2026-09-16)

- `tunnels.json` is now version 2 with a `profiles` array. `Tunnel` and `StoredData` decode with
  `decodeIfPresent` so version 1 files load unchanged; `group` defaults to "" and `profileID` to nil.
- A tunnel with `profileID` takes host, port, username, identity file and both secrets from the profile.
  `Tunnel.applying(_:)` produces the resolved copy that ssh runs. Removing a profile copies its settings and
  keychain items back into the tunnels that used it.
- Conflict detection runs `/usr/sbin/lsof -nP -iTCP:<port> -sTCP:LISTEN -F pc` before ssh starts. Output is
  one field per line (`p<pid>`, `c<command>`). It takes roughly 100 ms, so the manager runs it detached.
- Reconnect delay is `reconnectInterval << (attempt - 1)` capped at 300 s, reset on a successful connect, on
  a user-initiated connect and when the network path returns.
- Generated icon artwork from Codex came back with a semi-transparent alpha channel (95% of pixels below
  alpha 250) that turned into blotches after masking. `make-icon.swift` now forces every pixel opaque before
  drawing. Asking for "fully opaque, no transparency" in the prompt did not prevent it.

## Orphaned ssh sessions (2026-09-16)

- `pkill -x SecureTunnels` (which `make install` runs) sends SIGTERM. AppKit does not route that through
  `applicationWillTerminate`, so the ssh children kept running with parent pid 1 and held the local ports; the
  next instance then reported its own ports as in use. Fix: a `DispatchSourceSignal` for SIGTERM, SIGINT and
  SIGHUP calls `NSApp.terminate`, and `sessions.json` records every ssh pid so `SessionRegistry.killStaleSessions`
  can clean up after a crash. It only kills a pid whose command line is `/usr/bin/ssh -N ...` with the
  SecureTunnels marker, because pids get reused.

## Instant disconnects on another Mac (2026-09-16)

- A co-founder's install closed every tunnel right away. Nothing in the process code was machine specific, so
  the launch path now pre-checks the things that differ between Macs and reports them as the error: local port
  already taken, identity file missing or unreadable (opening it also triggers the macOS folder-access prompt
  for Desktop, Documents, Downloads and cloud drives), key permissions looser than 0600, and a quarantined
  askpass helper. The helper is executed by ssh, not by LaunchServices, so a right-click Open on the app does
  not clear its quarantine flag; the app removes the flag on its own helper with `removexattr` when it can.
- `NWPathMonitor` reports `.requiresConnection` for on-demand VPN links. Treat only `.unsatisfied` as offline.
- The connected marker can arrive split across two stdout reads; match on an accumulated buffer.

## Cloudflare Tunnels (2026-09-16)

- `URL.appendingPathComponent` percent-encodes `?`, so API paths with query strings must be built from the
  full string. A unit test on the recorded request caught this before any network call.
- cloudflared writes everything to stderr. A quick tunnel prints its URL inside a box of `|` characters and
  "Registered tunnel connection" once per edge connection; both were confirmed against cloudflared 2026.9.1.
- The tunnel token from `GET /cfd_tunnel/{id}/token` is passed as `TUNNEL_TOKEN` in the environment so it does
  not show in `ps`. It is fetched on every connect and never stored.
- Tunnels created with a local `config.yml` return an empty remote configuration, so they cannot be adopted;
  the list shows them as having no ingress in the dashboard.
- Adopting a tunnel must not call the provisioning path, which would overwrite the remote ingress with a
  single rule. Adopted tunnels only fetch the token and run.
- CLI backend: `cert.pem` holds a base64 "ARGO TUNNEL TOKEN" JSON block with `accountID`, `zoneID` and a
  service `apiToken`. The app only reads the ids for display; cloudflared itself uses that token against
  special endpoints (`/zones/{zone}/tunnels/{id}/routes`), so it is not reused with the public DNS API.
  `cloudflared tunnel list -o json` is the only list command; there is no command that lists DNS routes.

## Popover crash and empty list (2026-09-25)

- Empty popover: with 5 tunnels or fewer the list sat in a ScrollView sized only by maxHeight. MenuBarExtra
  sizes its window from the ideal size, and a ScrollView's ideal height is about zero, so the rows were laid out
  at height 0 (measured: 70 pt for header and footer instead of 180). The snapshot tool measured fittingSize,
  which does not collapse, so screenshots never showed it. `--popover-sizes` now prints the ideal and preferred
  heights for 0 to 8 tunnels.
- Crash: five reports, all EXC_BAD_ACCESS on the main thread inside the private DesignLibrary framework (system
  control styles), in `swift_task_isCurrentExecutor` with a corrupted executor pointer, during an animated
  window layout. DesignLibrary symbols are stripped, so the exact control is not identifiable. MenuBarExtra
  animated every resize and kept its SwiftUI content rendering while closed, so background reconnects kept
  re-rendering system switches and bordered buttons.
- Fix: no SwiftUI scenes. main.swift runs NSApplication; an NSStatusItem with a plain image, an NSPopover with
  animates = false whose NSHostingController is created on open and released on close, and an NSWindow owned by
  MainWindowController with sceneBridgingOptions [.toolbars, .title]. Popover rows have fixed heights, the list
  height is computed, and the switch and group buttons are drawn with plain shapes.
- On macOS 26 status item windows are owned by Control Center, not the app, so CGWindowList cannot confirm a
  status item. `--selftest` installs the real status item, opens and closes the real popover, and can capture
  the real main window; `--stress N` opens and closes the popover N times while cycling every tunnel's status.
