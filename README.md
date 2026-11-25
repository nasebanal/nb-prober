# NASEBANAL Prober

Check services on a private network from inside it and report the outcomes to [NASEBANAL Evolution](https://evolution.nasebanal.com). One small bash script on top of `curl`; it only makes outgoing requests, so nothing has to be opened in your firewall.

## 📋 Table of Contents

- [Overview](#overview)
- [Requirements](#requirements)
- [Terms of use](#terms-of-use)
- [Getting Started](#getting-started)
- [Install](#-install)
- [Running it as a service](#-running-it-as-a-service)
- [Commands](#commands)
- [How a check is judged](#how-a-check-is-judged)
- [Following the settings in Evolution](#following-the-settings-in-evolution)
- [Limits](#limits)
- [Testing](#testing)
- [Security](#security)
- [License](#license)

## 🚀 Overview

Evolution's external monitoring runs in the cloud, so it can only reach public URLs. A service on a private network (an intranet site, a staging cluster) cannot be monitored that way. `nb-prober` closes the gap with a **push monitor**:

- **You register a monitor in Evolution** (External monitoring), with the same settings as a cloud monitor (URL, method, expected status, keyword, timeout, interval), Network **Private**, and the probe that checks it. Choosing **New probe…** in its Probe field registers the probe together with the monitor and shows the probe's **key**, once. Evolution never requests that URL.
- **`nb-prober` runs inside your network** with the probe's key: it asks Evolution for the monitors of that probe, makes the request of each one when its interval is due, and reports the outcome (ok, status code, response time, error). That request is also its **heartbeat**: Evolution shows the probe as online while it hears it, and as offline when it stops.
- **Its own checker, nothing else to run**: it judges a response exactly as Evolution's checker does, so a monitor means the same thing whether it runs in the cloud or in your network. There is no exporter in between, and nothing is collected that Evolution cannot show.
- **Evolution is the one place for settings**: change a monitor on its screen and the probe uses the change on its next pass; nothing is configured on the probe but its key.
- **The key can do one thing**: list the probe's own monitors and report their results. It cannot read anything else in Evolution (it is not a personal access token), and it is replaced in one click (External monitoring > the probe list > the probe > Issue a new key).
- **Evolution records it like any other check**: the state, incidents, daily uptime, the report, the badge and the quality gates all work as for a cloud monitor.
- **Silence is a failure**: if a probe stops reporting, Evolution shows the monitor as down with "no report" after the interval plus a grace period, so a dead probe never looks healthy.
- **Survives a cut link**: results are buffered on disk and sent oldest first, 100 at a time, when the link returns; checking goes on from the last list of monitors in the meantime.

> **Status:** push monitors are available in NASEBANAL Evolution (External monitoring: register a probe, then a monitor on the Private network).

## 📦 Requirements

### Platform
- macOS or Linux

### Commands
- `curl` and [`jq`](https://jqlang.github.io/jq/).
- `bash` 3.2 or later (the script avoids bash 4 features); developed and tested with 5.3.
- Ordinary tools: `sed`, `awk`, `grep`, `head`, `tail`, `wc`, `date`.

### Environment
- `NB_PROBER_KEY` (required): the probe's key, `nbp_<probe id>_<secret>`, issued when the probe is registered in Evolution (shown once; if it is lost, issue a new one).
- `NB_ASSURANCE_BASE_URL`, `NB_PROBER_STATE_DIR`, `NB_PROBER_TICK` (1 to 60 seconds), `NB_PROBER_BUFFER_MAX`, `NB_PROBER_RETRY_WAIT` (optional): see `nb-prober -h`.

## ⚖️ Terms of use

`nb-prober` assumes all of the following:

1. **It runs on a machine you control, inside the network it checks.** It is the only thing that touches your private targets; Evolution only ever sees the outcomes.
2. **The key is kept where only the probe's user can read it**: a file readable by root only (mode 600) that a service reads, or your platform's secret store; not a shell profile, a unit file or a command line. (A tool that asks for a passphrase on a terminal, such as [NASEBANAL Secrets](https://github.com/nasebanal/nb-secrets), fits a run by hand, not a service.) It is least-privilege by construction (it reaches only this probe's monitors), but a leaked key can still report false results for them: replace it in Evolution at once.
3. **You trust what you register.** A monitor's URL comes from Evolution and `nb-prober` requests exactly that, so anyone who can edit your monitors can make your probe send a `GET` or `HEAD` to any `http` / `https` URL it can reach (the response is only judged, never sent back). Treat monitor editing as access to your network.
4. **You understand the [Limits](#limits).**

## 🛠 Getting Started

```bash
# 0. in Evolution: External monitoring > Register monitor > Network: Private > Probe: New probe... (a name such as office-tokyo).
#    Copy the key now: it is shown once.

# 1. put the script on your PATH
git clone https://github.com/nasebanal/nb-prober.git
nb-prober/bin/nb-prober --install      # links it into ~/.local/bin (or a directory you name); put that on your PATH
                                       # (nb-prober --uninstall removes that link again; the service is separate: nb-prober service delete)

# 2. try a check from this machine, the way a monitor would make it
nb-prober check http://intranet.example/health
nb-prober check http://intranet.example/ --method GET --expect-status 200 --keyword "Welcome" --timeout-ms 5000

# 3. check the setup
export NB_PROBER_KEY=nbp_...           # the probe's key
nb-prober doctor

# 4. in Evolution, register a monitor (Private: pick this probe), then run the probe
nb-prober list
nb-prober run
```

With the [`nb` command](https://github.com/nasebanal/nb-cli) (0.15.0 or later) installed, every command above also runs as `nb prober ...` (`nb` runs `nb-<name>` from your PATH), and `nb -h` lists it. `nb-prober` itself needs neither `nb` nor Node.

On a VM do not leave it running in an SSH session: it stops when you log out. Run it as a service: see [Running it as a service](#-running-it-as-a-service).

## 📥 Install

Once per machine. Each release carries the script `nb-prober` and its SHA-256, `nb-prober.sha256` (the [Releases](https://github.com/nasebanal/nb-prober/releases) page). The commands fetch the latest one, check the checksum and put the script in `/usr/local/bin`, where `sudo` finds it. Needs `curl` and [`jq`](https://jqlang.github.io/jq/).

### Ubuntu

```bash
sudo apt-get install -y curl jq
curl -fsSLO https://github.com/nasebanal/nb-prober/releases/latest/download/nb-prober
curl -fsSLO https://github.com/nasebanal/nb-prober/releases/latest/download/nb-prober.sha256
sha256sum -c nb-prober.sha256
sudo install -m 755 nb-prober /usr/local/bin/nb-prober
```

### macOS

```bash
brew install jq                      # curl is already there
curl -fsSLO https://github.com/nasebanal/nb-prober/releases/latest/download/nb-prober
curl -fsSLO https://github.com/nasebanal/nb-prober/releases/latest/download/nb-prober.sha256
shasum -a 256 -c nb-prober.sha256
sudo mkdir -p /usr/local/bin && sudo install -m 755 nb-prober /usr/local/bin/nb-prober
```

To pin a version, replace `latest/download` with `download/v0.1.0` (any release tag). Check it with `nb-prober --version` (a copy cloned from `main` says `dev`; a release says its version), and update by running the same commands again.

## 🧰 Running it as a service

`nb-prober run` stays in the foreground, which is right for a first try and wrong for a VM: it ends with your SSH session. In production register it as a service, so that it survives logout and reboot and is restarted if it dies. After [installing](#-install) it, Evolution's probe-key screen shows this command with your key filled in (Ubuntu and macOS):

```bash
nb-prober service create nbp_...        # or: nb prober service create nbp_...
```

The service lives in system directories, so every `service` command needs root. You do not type `sudo`: when you are not root, `nb-prober` runs itself again through `sudo` (once, with the script's real path, so `nb` need not be on root's PATH) and asks for your password. What `sudo` drops goes along as arguments: the key and `NB_ASSURANCE_BASE_URL`, when they came from the environment. `--dry-run` and `--root` need no root. Typing `sudo nb-prober service ...` yourself works as well, and is what to do where there is no terminal for the password.

It checks the key against Evolution first (a refused key installs nothing), puts the script at `/usr/local/bin/nb-prober`, keeps the key where only root can read it, and starts the service:

| | Ubuntu (systemd) | macOS (launchd) |
|---|---|---|
| Service | `/etc/systemd/system/nb-prober.service` | `/Library/LaunchDaemons/com.nasebanal.nb-prober.plist` |
| Key | `/etc/nb-prober/env` (mode 600) | in the plist (mode 600, root only) |
| Runs as | a locked-down dynamic user | `nobody` |
| State | `/var/lib/nb-prober` | `/var/db/nb-prober` |
| Logs | `nb-prober service logs -f` (journalctl) | `nb-prober service logs -f` (`/var/log/nb-prober.log`, bounded) |

The key is the argument, as with `cloudflared service install <token>`. An argument stays in your shell history and shows in `ps` while this one command runs; to avoid `ps`, pipe it (`printf '%s' 'nbp_...' | nb-prober service create`) or set `NB_PROBER_KEY`; to keep it out of the history, start the line with a space (where `HISTCONTROL=ignorespace` is set) or clear it afterwards. The service itself never has the key in its arguments: it reads it from a root-only file. To point the service at another Evolution (a local one, for example), add `--url`: `nb-prober service create nbp_... --url http://localhost:8791` (an exported `NB_ASSURANCE_BASE_URL` does the same). The address is kept in the service, like the key.

`nb-prober service status` shows the service and its last log lines. `nb-prober service logs` shows the log (`-f` follows it, `-n 200` shows more lines): `journalctl -u nb-prober` on Ubuntu (the system trims it), `/var/log/nb-prober.log` on macOS (`nb-prober` keeps it bounded itself: over 5 MiB it moves to `nb-prober.log.1` and starts a new file, so at most about 10 MB; launchd's own start-up errors go to `/var/log/nb-prober.err`). To keep the same bounded file when you run by hand, set `NB_PROBER_LOG=FILE`. `service restart`, `stop` and `start` use the key already stored, so none is given; `stop` lasts until the next boot (the service stays registered and starts again then). There is one service per machine, and `create` never takes an existing one over: it stops with "a service already exists" (naming its probe) and tells you to `nb-prober service delete` first and `create` again. To replace the key or the probe in one step, add `--force` (a new key for the same probe keeps its buffered results; another probe makes the old one go offline in Evolution, and its monitors report nothing until it is back). `nb-prober service delete` removes the service and the key (the state directory stays, since it holds results not yet sent). `--dry-run` shows what would be written.

Other systems, or only to try it: `nohup nb-prober run > ~/nb-prober.log 2>&1 &` survives the SSH session but not a reboot or a crash; or one pass a minute from cron (`flock` stops passes overlapping):

```cron
* * * * * . /etc/nb-prober/env && export NB_PROBER_KEY && flock -n /tmp/nb-prober.lock /usr/local/bin/nb-prober run --once >> /var/log/nb-prober.log 2>&1
```

### After a reboot

The service starts by itself at boot, before anyone logs in: on Ubuntu it is enabled in systemd (after the network is up), on macOS it is a launchd daemon with `RunAtLoad`. If Evolution cannot be reached yet, it keeps the last list of monitors, buffers the results and sends them when the link is back.

### If it stops

A probe that is down for less than a monitor's interval plus grace (10 minutes by default) leaves no trace: its results wait in the state directory and are sent when it is back. After that Evolution shows the probe **offline** and its monitors **down** with "no report". The service manager's restart is the whole recovery plan for one machine.

## 📖 Commands

Every command answers `-h`.

| Command | What it does |
|---|---|
| `run [--once] [--dry-run]` | Every `NB_PROBER_TICK` seconds (default 15, at most 60): list this probe's monitors (the heartbeat), check the ones that are due (a failed check is repeated once), buffer each outcome, and send the buffer oldest first, 100 at a time. `--once` does one pass and exits; `--dry-run` checks and prints but reports and keeps nothing |
| `list` | The monitors this probe checks: id, interval in minutes, method, state, URL |
| `check <url> [--method GET\|HEAD] [--expect-status CODE] [--keyword TEXT] [--timeout-ms MS]` | One check of a URL from this machine, printed as JSON, to try it before registering a monitor. Reports nothing, and needs no key. Exits 0 if the target is ok, 1 if not |
| `doctor` | Check `curl` and `jq`, the key and which probe it is, Evolution and the key's acceptance, and the state directory, without reporting anything. Exits 1 if anything is flagged |
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

`nb-prober` pulls; Evolution never pushes to it (that is what keeps your network closed to the outside). Every pass lists the monitors again, so a change on a monitor's screen reaches the probe within `NB_PROBER_TICK` seconds (at most 60):

| On the screen | The probe |
|---|---|
| add a monitor | checks it at once (it has never been checked) |
| change the URL, method, expected status, keyword or timeout | **checks it again at once** (within a pass) with the new values, then on its interval |
| change the interval | applies it from the last check time (and checks at once, like any edit) |
| disable a monitor | stops checking it |
| delete it, or move it to another probe | stops checking it; results still buffered for it are dropped when Evolution refuses them (404) |

Nothing else is configured on the probe: its key is all it needs. To move a probe to another machine, run `nb-prober` there with the same key (stop the old one first: two processes with one key check twice).

## ⚠️ Limits

Read this before you trust it:

- **A fault on the probe's own side looks like the target's.** If the machine running `nb-prober` loses its network or DNS, every check fails with `connection_failed`, exactly as it would if every target were down. Run it where its own connectivity is as reliable as the targets'.
- **Freshness is bounded by the interval.** Evolution has no "check now" for a push monitor; the next check is at the next due time, at most `NB_PROBER_TICK` seconds late, and a screen change is seen within the same time.
- **One probe, one machine.** There is no clustering: two `nb-prober` processes with the same key check twice and report twice (the duplicate is ignored by Evolution, which keys a result by its time, but it is wasted work). Register one probe, with its own key, per machine.
- **Results are kept up to 7 days.** Evolution refuses results older than that, so a link that is down for longer loses the oldest ones.
- **Your clock matters.** `checked_at` is the probe's clock (UTC). Evolution refuses a result more than 5 minutes in the future.
- **It is a thin script, not an agent.** It runs no commands received from the network; it only makes the requests of the monitors you registered.
- **HTTP only.** No TCP, ICMP, DNS or TLS-expiry checks; those are not in Evolution's monitors either.

## 🧪 Testing

```bash
test/run.sh
```

Needs `bash` and `jq`. Runs the whole suite against a test double of `curl` (`test/shim/curl`) that answers what `nb-prober` asks of Evolution and of the monitored targets from files, so no network and no real token is involved. It covers every command, the judgement of a response (status, keyword, HEAD, timeout, refused, a body cut at 1 MiB), a monitor's settings changing between passes, the buffering and flushing (including a cut link and batches of 100), the refusals (401 / 409, no key, a key of the wrong shape, a pass longer than 60 seconds), and that the key never appears in a command line or the output. The test double cannot catch a wrong `curl` flag: after changing how `nb-prober` calls `curl`, also try `nb-prober check` against a real server (a timeout, a redirect, a keyword, a refused port).

## 🔐 Security

See [SECURITY.md](SECURITY.md) for what is in scope and how to report a vulnerability privately.

## 📄 License

[MIT](LICENSE)
