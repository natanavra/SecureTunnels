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
