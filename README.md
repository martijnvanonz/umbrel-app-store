# MvO Homelab — Umbrel Community App Store

A community app store for [umbrelOS](https://umbrel.com) containing homelab utilities.

> Hardened fork of [empewoow/umbrel-app-store](https://github.com/empewoow/umbrel-app-store) (original by Matthijs, MIT licence kept). Changes: own ids (`mvo`, `mvo-ups-monitor`) so it never collides with upstream; image built by this repo's CI only, with GitHub Actions pinned to commit SHAs, base image pinned by digest and no `:latest` tag; shutdown also on `FSD` and after a configurable time on battery; `poweroff` is tried first. No telemetry or other outbound connections — the only connection is to the NUT server you configure.

## Add this store to your Umbrel

1. In umbrelOS, open the **App Store**
2. Click the **⋮** menu (top right) → **Community App Stores**
3. Paste this repository's URL and add it
4. The apps below appear under the "MvO Homelab" section

---

## 📦 UPS Monitor

Gracefully shuts down your Umbrel when a **remote NUT (Network UPS Tools) server** reports a low battery — using the **raw NUT protocol** (port 3493). No extra REST server, no SSH keys, no Portainer.

### Why this exists

umbrelOS has **no built-in UPS support** and — as of this writing — **no UPS/NUT app exists in any Umbrel store** (checked the official store's 394 apps and the major community stores). If your UPS is attached to another machine running `nut-server`, there was no persistent way to make Umbrel shut itself down during a long outage. Terminal changes don't survive reboots; this app (a real Docker container) does.

### How it works

- Polls your NUT server every 15 seconds via bash `/dev/tcp` — no `upsc` binary needed.
- `OL` (online) → nothing; clears the outage state when power returns.
- `OB` (on battery) → shuts down when the battery reaches your chosen %, after your chosen number of seconds on battery, or immediately when the UPS reports `LB` (critical low battery), whichever comes first.
- `FSD` (forced shutdown, set by the NUT master when it starts its own shutdown) → shuts down immediately.
- If the NUT server becomes unreachable **during** an outage, it assumes the UPS is failing and shuts down after a few polls (a NUT server on the same power dies with it).
- Powers the host off via `nsenter -t 1 … poweroff` (the same command as umbrelOS's Shutdown button), falling back to `systemctl poweroff`, then `shutdown -h now`. The container runs `pid: host` + `privileged`, so no sudo password needed. The reason is written to `/state/last_shutdown` and shown on the status page.

Logic adapted from [MarekWo/UPS_monitor](https://github.com/MarekWo/UPS_monitor) — changed from its REST-API approach to the raw NUT protocol so it works against a stock `nut-server`.

### Configuration

Open the app after installing — it has a **built-in settings page**. No environment variables, no terminal. Fields:

| Field | Default | Meaning |
|---|---|---|
| NUT server IP | _(required)_ | IP of the machine running `nut-server` |
| NUT server port | `3493` | NUT server port |
| UPS name | `ups` | UPS name on the NUT server |
| Shut down when battery drops to % | _(blank)_ | The main control. Blank = shut down only on the UPS's own critical low-battery signal. Set e.g. `20` to shut down earlier, with more margin. |
| Shut down after this many seconds on battery | _(blank = off)_ | Seconds of continuous power outage before shutting down, e.g. `90`. |
| Poll interval (seconds) | `15` | Seconds between polls of the NUT server. |

The app **always** shuts down when the UPS reports critical low battery or `FSD`, so you are protected even with the % left blank.

Settings are saved to the app's persistent storage and take effect within one poll interval.

Your NUT server must accept network queries. Test from any machine:
`printf 'GET VAR ups ups.status\nLOGOUT\n' | nc <nut-host> 3493`

## License

MIT
