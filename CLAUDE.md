# CLAUDE.md - nb-prober

One bash script, `bin/nb-prober`, on top of `curl` and `jq`: it checks the monitors of a probe name from inside a private network, with its own checker, and reports the outcomes to NASEBANAL Evolution (`nb-assurance-api`). It lives under `apps/` because it follows the Assurance contract (push monitors: `listMonitors?mode=push&probe=` and `reportMonitorResults`). The design and its decisions: `apps/docs/push-monitors-design.md`. MIT (`Copyright (c) 2026 NASEBANAL`). User docs: `README.md`. The workspace rules (git, PRs, commit prefixes) are in `apps/CLAUDE.md`.

## Rules

- **Outgoing requests only, and only to two places**: the Evolution API and the URLs of the probe's own monitors (`http` / `https`, `GET` / `HEAD`). Never run anything received from the network.
- **The judgement is Evolution's checker, not a new one**: `nb-assurance-api` `src/services/checker.ts` (redirects followed, 2xx / 3xx when no status is set, keyword on `GET` in the first 1 MiB, `response_ms` = time to the headers, one immediate retry, the final attempt reported). When that file changes, change `probe_once` and the README table with it; a monitor must mean the same in the cloud and on a probe.
- **Settings live in Evolution only**: every pass re-reads the monitors; nothing about a monitor is configured on the probe (no config file, no per-monitor flags). Do not add one.
- **The token never appears in a command line, a log or a test output**: curl gets it on stdin (`-K -`). Tests use a dummy token and assert it is not in `args.log`.
- **Silence is a failure**: a probe that stops reporting is shown by Evolution as `no_report`. Do not paper over it (no fake results while Evolution is unreachable: buffer the real ones).
- **Never lose data silently, never loop for ever**: a report that can never be accepted (400 / 404 / 409) is dropped with a warning; one that may be accepted later (no answer, 5xx, 401 / 403) stays in the buffer.
- **The script's help is the comment block after the shebang** (the same layout as `nb`, `nb-secrets` and `nb-quickstarts`: Usage, one description line, Commands, Options). `nb -h` reads its first line (`# nb-prober - ...`), so keep that line one sentence under 100 characters. Every command answers `-h`; run `bin/nb-prober -h` after changing the header.
- Keep it dependency-light: bash 3.2-safe, `curl`, `jq`, ordinary POSIX tools. No new runtime dependency without a reason that outweighs "the whole script can be read in one sitting".
- Error values and field names come from the contract (`nb-api-specs` `packages/assurance`): `timeout`, `connection_failed`, `unexpected_status`, `keyword_not_found` (never `no_report`, which only the server writes). Change them together with the spec.
- Run `bin/nb-prober -h`, `test/run.sh` and `shellcheck bin/nb-prober test/run.sh test/shim/curl` before proposing a change. The test double cannot catch a wrong `curl` flag: after changing how `curl` is called, also run `nb-prober check` against a real local server (timeout, redirect, keyword, refused port, a body over 1 MiB).
- Docs are English. Plain ASCII numbering (no circled digits).
- Changes go through pull requests; CI (`check`, `shellcheck`) must pass. Never merge on the user's behalf.
- `post-daily.yml` and `post-on-deploy.yml` are copies of `nb-app-template`'s, verbatim (the apps/ rule), even though this repository is not deployed.
