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
