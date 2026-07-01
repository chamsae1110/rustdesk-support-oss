# Build & Run

## 1. Customer client (`support-client.exe`)

The client is a PowerShell script wrapped into a single self-extracting `.exe`
with the built-in Windows **IExpress** tool. This repo ships with generic
`example.com` placeholders; your real server config is injected at build time
(the distributed exe must have the values baked in, since end-user machines have
no `RS_*` environment variables).

1. Copy `client/build.config.example` → `client/build.config` (git-ignored) and
   fill in your real `RS_SERVER` / `RS_RELAY` / `RS_PORTAL` / `RS_KEY` (the
   server's **public** key, `id_ed25519.pub`) / `RS_ORG`.
2. Build:
   ```powershell
   powershell -ExecutionPolicy Bypass -File client\build-client.ps1
   ```
   This injects your values into a build copy, wraps it with IExpress, and
   produces `support-client.exe` (path + SHA256 printed at the end).

For CI / automated signing (e.g. SignPath), run `build-client.ps1` on a Windows
runner with `build.config` provided as a secret, then submit the resulting exe
to the signing pipeline.

> Reproducible/stable builds matter for Windows SmartScreen reputation: a
> byte-identical rebuild keeps its reputation, and a code-signing certificate
> lets reputation accrue across rebuilds. Sign the produced `.exe` before
> distribution (this project is a candidate for a free OSS signing certificate
> via the SignPath Foundation).

## 2. Broker portal

```bash
cd portal
cp ../.env.example .env      # then edit .env with a strong AGENT_PASS + random SESSION_SECRET
docker compose up -d --build
```

The portal listens on `127.0.0.1:3010` by default and is meant to be exposed
over HTTPS via your own reverse proxy / tunnel. It has **no external npm
dependencies**.

## 3. Operator watcher

On the agent PC, run `agent/agent-client.ps1` once (configures RustDesk to the
server + registers the `rustdesk://` handler), then run
`agent/agent-watcher.ps1` and enter the master password to start auto-connecting
to waiting customers.

## Requirements

- Windows 10/11 for the client and agent tooling (PowerShell 5.1+).
- A self-hosted RustDesk server (`hbbs`/`hbbr`, OSS) reachable from clients.
- Docker (or Node 18+) for the portal.
