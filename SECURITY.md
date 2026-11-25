# Security policy

## Scope

`nb-prober` runs inside your network, asks NASEBANAL Evolution which URLs to check, has `blackbox_exporter` check them, and reports the outcomes. It makes outgoing requests only. Read [Terms of use](README.md#terms-of-use) and [Limits](README.md#limits) first.

In scope, for example: a way to make it send the token anywhere but your Evolution API, to print or log the token, to request a URL that is not one of your monitors' targets or your `blackbox_exporter`, to run a command received from the network, or to write outside its state directory.

Out of scope: what a monitor's target does with the request, and an attacker who already runs code as the user that runs the prober.

## Reporting

Please report privately through GitHub: **Security** tab, **Report a vulnerability** (private vulnerability reporting). Do not open a public issue for a vulnerability, and never include a real token in any report.

This is a small project maintained on a best-effort basis; there is no response-time guarantee.
