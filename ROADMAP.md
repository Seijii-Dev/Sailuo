# Sailuo — Repository Roadmap & File Structure

This document maps every file in the repository and what it does. The codebase has no web dashboard; it is a set of GitHub Actions workflows, PowerShell/Bash setup scripts, and an Android UI reference client.

## Top level

| File | Purpose |
|---|---|
| `README.md` | Project overview, setup flow, validation notes. |
| `FORK-GUIDE.md` | Guide for forking and syncing the template. |
| `ANNOUNCEMENT-LOGIN-SUSPEND-FIX.md` | Announcement about login/suspend fixes. |
| `ROADMAP.md` | This file — repository structure and roadmap. |
| `.gitignore` | Ignores local credentials, `.env`, `out/`, `node_modules/`, Vercel output. |

## `.github/`

| Path | Purpose |
|---|---|
| `.github/FUNDING.yml` | GitHub Sponsors/funding configuration. |
| `.github/workflows/rdp-6h.yml` | Main workflow: provisions a Windows/Linux RDP session on a GitHub-hosted runner, installs software, sets up Tailscale or Portmap access, keeps the session alive, persists state, and auto-renews. |
| `.github/workflows/validate-desktop.yml` | Parses and validates desktop diagnostics/cleanup scripts on Windows runners. |
| `.github/workflows/validate-host-tools.yml` | Installs and verifies host development tools. |
| `.github/workflows/validate-maintenance.yml` | Validates desktop maintenance (Explorer prefs, Lightshot install). |
| `.github/workflows/validate-portmap.yml` | Validates Portmap/OpenVPN configuration without exposing public RDP. |
| `.github/workflows/validate-tailscale.yml` | Installs and verifies the signed Tailscale package. |

## `assets/`

| File | Purpose |
|---|---|
| `assets/rdp-extras.json` | Per-repo configuration (wallpaper, debloat, storage boost, RDP user, etc.). |
| `assets/rdp-free-banner.jpg` | Banner image. |
| `assets/sailuo-wallpaper.jpg` | Default desktop wallpaper. |
| `assets/wallpaper-win10.jpg` | Windows 10 style wallpaper. |
| `assets/wallpaper.jpg` | Generic wallpaper. |

## `docs/`

| File | Purpose |
|---|---|
| `docs/DESKTOP-MAINTENANCE.md` | Desktop maintenance notes. |
| `docs/HOST-DEVELOPMENT-TOOLS.md` | Host development tools documentation. |
| `docs/WINDOWS-DEPENDENCIES-AND-SYNC.md` | Windows dependency installation and sync notes. |

## `scripts/`

Shared Windows/PowerShell (and one Bash) scripts invoked by the workflow.

| File | Purpose |
|---|---|
| `scripts/lib-common.ps1` | Shared helpers: logger, registry helpers, config reader (`rdp-extras.json`), Default profile hive manager, status file reader/writer (`out/rdp-status.json`), desktop icon generator. |
| `scripts/cleanup-actions.ps1` | Cleans up previous workflow runs on the runner. |
| `scripts/setup-rdp.ps1` | Base RDP setup: creates the admin user, enables port 3389, configures UAC/admin privileges, creates the user profile, sets compatibility/environment variables. |
| `scripts/restore-state.ps1` | Restores a saved session snapshot from a GitHub Release (encrypted AES-256 archive) into the user profile. |
| `scripts/optimize-storage.ps1` | Frees disk space on the runner (toolcache, SDKs, caches, Windows Update cache). |
| `scripts/setup-win10.ps1` | Applies the Windows 10 visual style and dark theme. |
| `scripts/setup-explorer.ps1` | Explorer and desktop tweaks. |
| `scripts/setup-media.ps1` | RDP audio and camera redirection. |
| `scripts/setup-sailuo.ps1` | XyDesk/Sailuo Remote host setup (AVC444, ClearType, audio, firewall). |
| `scripts/setup-extras.ps1` | Installs extra applications (7-Zip, Chrome, Lightshot, wallpaper). |
| `scripts/setup-host-tools.ps1` | Installs host development tools. |
| `scripts/setup-akses.ps1` | Sets up Tailscale private access (installs Tailscale, joins the tailnet). |
| `scripts/setup-portmap.ps1` | Sets up Portmap/OpenVPN access as an alternative to Tailscale. |
| `scripts/setup-linux-rdp.sh` | Linux desktop RDP / plain Linux SSH VPS setup (XRDP/SSH + Tailscale). |
| `scripts/publish-status.ps1` | Publishes `out/rdp-status.json` to the `status` branch for the dashboard/clients. |
| `scripts/keepalive.ps1` | Session keepalive guard: keeps services alive, heals desktop shortcuts, runs 4-minute auto-checkpoint to GitHub Release. |
| `scripts/persist-state.ps1` | Saves the session state (profile, browser logins, downloads) as an encrypted archive to a GitHub Release. |
| `scripts/finalize-rdp.ps1` | Stops the session and clears published status. |
| `scripts/diagnose-desktop.ps1` | Collects desktop diagnostics into a JSON report. |

## `qa-android-ui/`

Reference Android client (Kotlin) UI components and tests.

| File | Purpose |
|---|---|
| `qa-android-ui/RdpOptions.kt` | RDP option data/UI. |
| `qa-android-ui/RdpOptionsTest.kt` | Tests for RdpOptions. |
| `qa-android-ui/SessionControls.kt` | Session control UI. |
| `qa-android-ui/SessionControlsRealRenderTest.kt` | Real-render tests for session controls. |
| `qa-android-ui/XyDiscordVoiceStage.kt` | Voice stage UI component. |
| `qa-android-ui/bg_rdp_desktop.png` | Background image asset. |

## `tools/`

| File | Purpose |
|---|---|
| `tools/check-tunnel.py` | Checks whether a host:port tunnel is reachable from the internet via check-host.net. |

## Roadmap

### Done
- Full English translation of the codebase (scripts, docs, workflows, UI, brand kit).
- Removed games, self-hosted runners, anti-VM/anti-VPN/cracked-software tooling.
- Removed archived directories (`web/`, `deploy/`, `relay-panel/`, `integrasi-xydesk/`).
- Removed the web dashboard (`web-next/`).
- Rebranded from XyRDP/RdpFree/XyDesk to Sailuo.
- Removed third-party attribution.
- Created the `Sailuo` GitHub repository and pushed `main`.

### Possible next steps
- Add an English-language README section describing the new Sailuo branding and domain.
- Re-add a lightweight web dashboard (optional) under a new path.
- Add CI for PowerShell script parsing and Python linting.
- Document the Android client build/setup separately.
- Replace the placeholder dashboard URL (`sailuo.projectkal.my.id`) with the production domain.
