# Security policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Use GitHub's private reporting
([Security → Report a vulnerability](../../security/advisories/new)) or email the address on the
maintainer's GitHub profile. You will get an acknowledgement within a few days; if the report is
valid we will ship a fix and credit you unless you prefer otherwise.

## Supported versions

The project ships continuously from `main`; only the latest release is supported. Re-running the
installer upgrades an existing host in place.

## Scope

In scope:

- The bridge (`Bridge/`) — auth, pairing, tickets, attachment handling, the loopback invariant.
- The installer (`setup/install.sh`) — it runs as root.
- The apps (`Apps/`, `Sources/`) — credential storage, URL/QR handling, rendering of model output.

Out of scope: vulnerabilities in Hermes itself (report those upstream), in Tailscale, or in Apple's
platform frameworks.

## What the design promises

- The bridge binds `127.0.0.1`. Exposure is `tailscale serve`'s job; there is no supported mode in
  which the bridge listens on a public interface.
- A pairing code is single-use and expires. Every authenticated request mints its own 30-second
  ticket; tickets are never session credentials and are consumed by exactly one request.
- Device registration, revocation and the audit trail are per device.
- The upstream gateway token never leaves the host and is never returned to a client.
- The apps keep the device private key in the Keychain with `ThisDeviceOnly` accessibility.

The full threat model, including what the bridge deliberately refuses to do, is in
[`docs/SECURITY.md`](docs/SECURITY.md).
