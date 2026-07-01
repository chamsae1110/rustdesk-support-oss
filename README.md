# Self-Hosted Remote Support (RustDesk wrapper)

An open-source, self-hostable remote-support toolkit built on top of
[RustDesk](https://github.com/rustdesk/rustdesk) (OSS). It gives a small
one-file customer client, an operator auto-connect watcher, and a
zero-dependency broker portal, so a support agent can help a customer with a
single download-and-run — no account, no ID typing.

## What it does

- **Customer client** (`client/support-client.ps1` → `support-client.exe`):
  the customer downloads and runs one file. It configures RustDesk to point at
  the operator's self-hosted server, registers itself with the broker portal,
  and enables service-free auto-accept (a per-session random password written
  to RustDesk's local config) so the agent connects without the customer
  clicking "Accept". On close (or when the session ends) it fully tears down:
  invalidates the session password, resets approve-mode, removes itself from
  the portal, and terminates RustDesk. The RustDesk window is moved off-screen
  so the customer only sees a small "Remote Support" launcher.
- **Operator watcher** (`agent/agent-watcher.ps1`): polls the broker portal's
  waiting room and auto-connects (`rustdesk --connect <id> --password <pw>`) to
  the newest waiting customer (1:1). Deletes the peer config before connecting
  so each session opens with the operator's default view settings.
- **Broker portal** (`portal/server.js`): a ~single-file Node HTTP service (no
  external deps) that hosts the download, a master-login-protected waiting
  room, and register / heartbeat / unregister APIs. Heartbeat-based liveness
  removes dead/stale clients automatically.

## Security model

Trust rests on two secrets that are **never** in this repo: the RustDesk
server's **private** key (`id_ed25519`, stays on the server) and the portal
**master password + session secret** (see `.env.example`). Everything in this
repository — including the RustDesk **public** key and the operator's public
domains — is non-secret by design. Publishing the client source does not weaken
the system: an attacker still needs the private server key and master password
to connect to anyone.

## Layout

```
client/    customer one-file client (PowerShell + IExpress) + build script — the signed artifact
agent/     operator auto-connect watcher + RustDesk-setup helper
portal/    broker portal (Node, no deps) + Docker
docs/      notes
```

Server hostnames and the RustDesk public key are generic `example.com`
placeholders in this repo; supply your real values via `client/build.config`
(see [BUILD.md](BUILD.md)) so they are never committed.

## Build & run

See [BUILD.md](BUILD.md). RustDesk itself is **not** bundled — the client
downloads the official RustDesk binary at runtime (or uses a bundled copy you
provide). RustDesk is licensed AGPL-3.0; this wrapper is MIT (see
[LICENSE](LICENSE)) and is an independent work that invokes RustDesk as an
external program.

## Status

Functional and in production use for a small Korean support operation. Customer
UI strings are Korean. Contributions welcome.
