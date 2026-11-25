# NASEBANAL Prober

Check services on a private network from inside it and report the outcomes to [NASEBANAL Evolution](https://evolution.nasebanal.com). One small bash script on top of `curl`; it only makes outgoing requests, so nothing has to be opened in your firewall.

## 📋 Table of Contents

- [Overview](#overview)
- [Requirements](#requirements)
- [Terms of use](#terms-of-use)
- [Getting Started](#getting-started)
- [Commands](#commands)
- [How a check is judged](#how-a-check-is-judged)
- [Following the settings in Evolution](#following-the-settings-in-evolution)
- [Limits](#limits)
- [Testing](#testing)
- [Security](#security)
- [License](#license)

## 🚀 Overview

Evolution's external monitoring runs in the cloud, so it can only reach public URLs. A service on a private network (an intranet site, a staging cluster) cannot be monitored that way. `nb-prober` closes the gap with a **push monitor**:

- **You register the monitor in Evolution**, with the same settings as a cloud monitor (URL, method, expected status, keyword, timeout, interval) plus a probe name (for example `office-tokyo`). Evolution never requests that URL.
- **`nb-prober` runs inside your network**: it asks Evolution for the monitors of its probe name, makes the request of each one when its interval is due, and reports the outcome (ok, status code, response time, error).
- **Its own checker, nothing else to run**: it judges a response exactly as Evolution's checker does, so a monitor means the same thing whether it runs in the cloud or in your network. There is no exporter in between, and nothing is collected that Evolution cannot show.
- **Evolution is the one place for settings**: change a monitor on its screen and the probe uses the change on its next pass; nothing is configured on the probe but its name and token.
- **Evolution records it like any other check**: the state, incidents, daily uptime, the report, the badge and the quality gates all work as for a cloud monitor.
- **Silence is a failure**: if a probe stops reporting, Evolution shows the monitor as down with "no report" after the interval plus a grace period, so a dead probe never looks healthy.
- **Survives a cut link**: results are buffered on disk and sent oldest first, 100 at a time, when the link returns; checking goes on from the last list of monitors in the meantime.

> **Status:** push monitors are being added to Evolution (the design is in [nb-apps `docs/push-monitors-design.md`](https://github.com/nasebanal/nb-apps/blob/main/docs/push-monitors-design.md)). Until they are released, `nb-prober` has nothing to report to; `check` already works.

## 📦 Requirements

### Platform
- macOS or Linux

### Commands
- `curl` and [`jq`](https://jqlang.github.io/jq/).
- `bash` 3.2 or later (the script avoids bash 4 features); developed and tested with 5.3.
- Ordinary tools: `sed`, `awk`, `grep`, `head`, `tail`, `wc`, `date`.

### Environment
- `NB_PROBER_TOKEN` (required): an Evolution API token (a personal access token). Use **a dedicated token-only user for each probe**: a token has the rights of its user, so do not use your own.
- `NB_ASSURANCE_BASE_URL`, `NB_ACTIVE_ORGANIZATION_ID`, `NB_PROBER_NAME`, `NB_PROBER_STATE_DIR`, `NB_PROBER_TICK`, `NB_PROBER_BUFFER_MAX`, `NB_PROBER_RETRY_WAIT` (optional): see `nb-prober -h`.

## ⚖️ Terms of use

`nb-prober` assumes all of the following:

1. **It runs on a machine you control, inside the network it checks.** It is the only thing that touches your private targets; Evolution only ever sees the outcomes.
2. **The token is a dedicated, least-privilege one**, kept in a secret store (for example [NASEBANAL Secrets](https://github.com/nasebanal/nb-secrets): `nb-secrets run --only NB_PROBER_TOKEN ~/.secrets/prober.env.age -- nb-prober run ...`), not in a shell profile or a unit file in plaintext.
3. **You trust what you register.** A monitor's URL comes from Evolution and `nb-prober` requests exactly that, so anyone who can edit your monitors can make your probe send a `GET` or `HEAD` to any `http` / `https` URL it can reach (the response is only judged, never sent back). Treat monitor editing as access to your network.
4. **You understand the [Limits](#limits).**

## 🛠 Getting Started

```bash
# 1. put the script on your PATH
git clone https://github.com/nasebanal/nb-prober.git
nb-prober/bin/nb-prober --install      # links it into ~/.local/bin (or a directory you name); put that on your PATH

# 2. try a check from this machine, the way a monitor would make it
nb-prober check http://intranet.example/health
nb-prober check http://intranet.example/ --method GET --expect-status 200 --keyword "Welcome" --timeout-ms 5000

# 3. check the setup (a dedicated Evolution token, see Requirements)
export NB_PROBER_TOKEN=...
nb-prober doctor --probe office-tokyo

# 4. in Evolution, register a push monitor (URL, settings, probe name "office-tokyo"), then run the probe
nb-prober list --probe office-tokyo
nb-prober run --probe office-tokyo
```

With the [`nb` command](https://github.com/nasebanal/nb-cli) (0.15.0 or later) installed, every command above also runs as `nb prober ...` (`nb` runs `nb-<name>` from your PATH), and `nb -h` lists it. `nb-prober` itself needs neither `nb` nor Node.

To keep it running, start `nb-prober run` under your service manager (systemd, launchd, a container) and let that restart it. A systemd unit, for example:

```ini
[Service]
ExecStart=/usr/local/bin/nb-prober run --probe office-tokyo
EnvironmentFile=/etc/nb-prober.env      # NB_PROBER_TOKEN=...   (mode 600)
Restart=always
```

## 📖 Commands

Every command answers `-h`.

| Command | What it does |
|---|---|
| `run [--probe NAME] [--once] [--dry-run]` | Every `NB_PROBER_TICK` seconds (default 15): list this probe's monitors, check the ones that are due (a failed check is repeated once), buffer each outcome, and send the buffer oldest first, 100 at a time. `--once` does one pass and exits; `--dry-run` checks and prints but reports and keeps nothing |
| `list [--probe NAME]` | The monitors assigned to the probe: id, interval in minutes, method, state, URL |
| `check <url> [--method GET\|HEAD] [--expect-status CODE] [--keyword TEXT] [--timeout-ms MS]` | One check of a URL from this machine, printed as JSON, to try it before registering a monitor. Reports nothing. Exits 0 if the target is ok, 1 if not |
| `doctor [--probe NAME]` | Check `curl` and `jq`, the token, Evolution and the token's acceptance, and the state directory, without reporting anything. Exits 1 if anything is flagged |
| `--install [DIR]` | Link this script into `DIR` (default `~/.local/bin`) so `nb-prober` is on your PATH. A symlink, so `git pull` updates it; it never replaces a file or link it did not make, and prints the line to add to your shell if `DIR` is not on your PATH |

## 🔎 How a check is judged

The same as Evolution's own checker (`nb-assurance-api` `src/services/checker.ts`), so a monitor reads the same wherever it runs:

| | |
|---|---|
| Request | the monitor's method (`GET` or `HEAD`), redirects followed (up to 20), only `http` / `https`, `User-Agent: NASEBANAL-Prober/<version>` |
| ok | the status is the expected one; with none set, any 2xx or 3xx |
| keyword | with a keyword and `GET`, the first 1 MiB of the body must contain it (ignored for `HEAD`) |
| `response_ms` | the time until the response headers arrive (a keyword check's body read is not counted) |
| `timeout` | no complete answer within the monitor's timeout (no status code is reported) |
| `connection_failed` | DNS, refused connection, TLS or any other failure to get an answer (no status code) |
| `unexpected_status` | an answer with a status that does not count as ok (the status is reported) |
| `keyword_not_found` | the answer was ok but the keyword is not in the body |
| retry | a failed check is repeated once at once; the final attempt is the one reported |

## 🔄 Following the settings in Evolution

`nb-prober` pulls; Evolution never pushes to it (that is what keeps your network closed to the outside). Every pass lists the monitors again, so a change on a monitor's screen reaches the probe within `NB_PROBER_TICK` seconds:

| On the screen | The probe |
|---|---|
| add a monitor | checks it at once (it has never been checked) |
| change the URL, method, expected status, keyword or timeout | uses the new values from the next check |
| change the interval | applies it from the last check time |
| disable a monitor | stops checking it |
| delete it, or change its probe name or mode | stops checking it; results still buffered for it are dropped when Evolution refuses them (404 / 409) |

Nothing else is configured on the probe: its name and token are all it needs, which also means a probe can be replaced by starting another with the same name.

## ⚠️ Limits

Read this before you trust it:

- **A fault on the probe's own side looks like the target's.** If the machine running `nb-prober` loses its network or DNS, every check fails with `connection_failed`, exactly as it would if every target were down. Run it where its own connectivity is as reliable as the targets'.
- **Freshness is bounded by the interval.** Evolution has no "check now" for a push monitor; the next check is at the next due time, at most `NB_PROBER_TICK` seconds late, and a screen change is seen within the same time.
- **One probe, one machine.** There is no clustering: two `nb-prober` processes with the same probe name check twice and report twice (the duplicate is ignored by Evolution, which keys a result by its time, but it is wasted work). Give each machine its own probe name.
- **Results are kept up to 7 days.** Evolution refuses results older than that, so a link that is down for longer loses the oldest ones.
- **Your clock matters.** `checked_at` is the probe's clock (UTC). Evolution refuses a result more than 5 minutes in the future.
- **It is a thin script, not an agent.** It runs no commands received from the network; it only makes the requests of the monitors you registered.
- **HTTP only.** No TCP, ICMP, DNS or TLS-expiry checks; those are not in Evolution's monitors either.

## 🧪 Testing

```bash
test/run.sh
```

Needs `bash` and `jq`. Runs the whole suite against a test double of `curl` (`test/shim/curl`) that answers what `nb-prober` asks of Evolution and of the monitored targets from files, so no network and no real token is involved. It covers every command, the judgement of a response (status, keyword, HEAD, timeout, refused, a body cut at 1 MiB), a monitor's settings changing between passes, the buffering and flushing (including a cut link and batches of 100), the refusals (401 / 409, no token, bad probe name), and that the token never appears in a command line or the output. The test double cannot catch a wrong `curl` flag: after changing how `nb-prober` calls `curl`, also try `nb-prober check` against a real server (a timeout, a redirect, a keyword, a refused port).

## 🔐 Security

See [SECURITY.md](SECURITY.md) for what is in scope and how to report a vulnerability privately.

## 📄 License

[MIT](LICENSE)
