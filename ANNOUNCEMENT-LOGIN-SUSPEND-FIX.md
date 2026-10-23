# ANNOUNCEMENT — Login Fix on Every Refresh & Anti-Suspend (10 Oct 2026)

> **Required update for every fork user.** Sync your fork now — the fix is already on `main` (`5c7df72` TOTAL web login overhaul — anti login loop).

## 1. Login on every refresh — FIXED (no more nagging)

**Previous problem:** every browser refresh asked you to log in again.

**Fix:**
- The frontend now sends cookies with `credentials: 'include'` (it did not before) → the `ghs`/`sid` session (AES-256-GCM) is sent on every request
- Session lifetime extended **7 days → 30 days** (GitHub) and **12 hours → 30 days** (admin)
- `localStorage: xyrdp_me_cache` cache — a refresh still opens the dashboard first while checking in the background

**Your action (once, after this update goes live on Vercel, about 1 minute):**
1. Open `xyrdp-dash.vercel.app` → if it still asks you to log in, **Clear cookies** for the site (Chrome: padlock icon → Cookies → delete `ghs` & `sid`) or `Ctrl+Shift+Del` → Cookies
2. Log in once more → after that it **lasts 30 days**, and refreshing no longer logs you out
3. Do not change `SESSION_SECRET` in Vercel (≥32 chars). If you change it, every user gets logged out.

## 2. Why can login through the Dashboard get suspended, while a manual fork stays safe?

| Method | Safe? | Why |
|---|---|---|
| **Manual fork on github.com** (`xykal/XyRDP` → `Use this template` → `Create new repository`) | **SAFEST** | A native GitHub action. Rate limits apply per account. The workflow runs in `you/RdpFree` with your token. It does not go through Vercel IPs. |
| **Dashboard “Sign in with GitHub” (OAuth)** | Risky when spammed | The dashboard uses your token to `generate repo` + `set secrets` + `dispatch workflow` through the **API from Vercel IPs**. If many users click “Create Repo” + “Start” at the same time within 1-2 minutes, it looks like **automation spam / abuse** → suspension flag. |

**Dashboard anti-suspend fixes (already live):**
- **Limit of 2 Start clicks per 5 minutes per user/IP** → above that: `429 Wait Xs more`
- **Dispatch is blocked while a `queued/in_progress` run exists** → you must `Stop` it first
- All of this is explained on the `/guide` page in a new section

**How to use the dashboard safely:**
1. **Safest: fork manually first** on github.com (name it `RdpFree`), wait 1-2 minutes, then log in to the dashboard (it automatically uses `you/RdpFree`)
2. Do not spam “Create Repo” / “Start” — wait for the run to fthissh
3. Do not create 5+ RDP repositories in an hour with one account
4. Fill in the required secrets: `RDP_PASSWORD` (min 8) + `TAILSCALE_AUTH_KEY` (`tskey-auth-...`, never share it publicly)

## 3. How to sync your fork (gets the boost-stuck and login fixes)

**Fastest (web):**
1. Open your fork `github.com/you/RdpFree` → **Sync fork** → **Update branch** (or `Fetch upstream` if you never have)
2. If the button is missing: `Settings` → `Actions` → `General` → make sure **Allow all actions** + **Workflow permissions: Read and write**
3. Check the `Actions` tab → the `RdpFree - 6-Hour RDP` workflow is active (do not Disable it)

**Via git (alternative):**
```bash
git clone https://github.com/you/RdpFree.git
cd RdpFree
git remote add upstream https://github.com/xykal/XyRDP.git
git fetch upstream
git merge upstream/main
git push origin main
```

After syncing, the boost no longer gets stuck (previously `Get-ChildItem -Recurse` in `C:\Android` hung for 10 minutes → now FAST at `3m25s`, proven by run #86). Check `Actions` → the ` Boost Storage` log.

## 4. Black wallpaper & microphone — FIX `1c0b668`

**The black wallpaper is a Windows Server default, not XyDesk.** XyDesk only hosts the RDP session — `mstsc` and XyDesk see the same session. The repo already ships `assets/wallpaper.jpg` + `wallpaper-win10.jpg` + `rdp-extras.json: wallpaper=true`. If it is still black:

- **The client turned the wallpaper off** (most common):
  - `mstsc` → `Show Options` → `Experience` → check `Desktop background / Wallpaper`
  - `XyDesk Remote` → `Settings` → `Wallpaper` → **ON** (OFF deliberately means black, saving 30% bandwidth)
- **Fix `1c0b668`:** `setup-xydesk.ps1` now sets `fNoRemoteDesktopWallpaper=0` + `WallpaperStyle=10` through Policy (without writing `WinStations`, so `3389` stays up) → the next run **will show** the wallpaper when the client is ON. New uploads through dashboard `Settings → Upload Wallpaper` are applied immediately as well.

**Microphone — SUPPORTED & ALREADY ACTIVE:**
- The host now runs `fDisableAudio=0` + `fDisableAudioCapture=0` + `AudioQualityMode=2 (High)` + `AudioEndpointBuilder` (policy override). The log confirms phone mic redirection is active.
- **XyDesk:** phone → `Settings` → `Apps` → `XyDesk` → `Permissions` → `Microphone Allow` → XyDesk → `Settings` → `Enable Microphone ON` → in RDP `mmsys.cpl` → `Recording` → `Remote Audio` → test with `Sound Recorder`.
- **mstsc:** edit the `.rdp` file to add `audiomode:i:0` + `audiocapturemode:i:1` + `microphone:redirection:i:1`.

---
Credit: **KallAncrit** • RdpFree • The web dashboard does not come with the fork — only the script repository.
**Update `d5e554f` — maximum free disk + DirectX anti-DxError:**
- `optimize-storage.ps1` defaults to **full debloat** (not light): Edge is **actually force-removed** (`Edge`/`EdgeCore` folders + every `*Edge*.lnk` shortcut under `Public/Desktop`/`Default/Desktop`/`Start Menu`), R + OneDrive + Clipchamp Appx are removed, plus `DeliveryOptimization cache`, `vcpkg`, and `hostedtoolcache/stack` — freeing **110-140GB**. WebView2 is kept so apps do not break. Chrome is no longer required — Edge is still removed with `full`.
- Default `RDP_USER` stays `xyadmin` (not `runneradmin`). Use `runneradmin` only if you set `RDP_USER=runneradmin` in the workflow (highest built-in privileges). So **do not use runneradmin** if you want a separate user — leave the default.

**Update `5c7df72` — TOTAL web login overhaul (people who were already logged in still saw the login page):**
- Backend `api/index.js`: Secure `cookieHeader` via `x-forwarded-proto` + `VERCEL_ENV` (previously sometimes not sent), `ghUserDebug` reason (`no_cookie`, `unseal_failed`, `expired`), `/auth/status` returns `debug` + sliding refresh of `ghs` for 30d when less than 7d remains (previously it expired and logged out immediately), every `Set-Cookie` uses `req`.
- Frontend `index.html`: `boot()` 7s timeout + 2x retry, `localStorage 12h` fallback, no immediate `showLogin` on a network 500, `api()` `credentials:include` + `me_at`, `showLogin` shows debug info in `ghNote`.

Live: `xyrdp-dash.vercel.app` (Vercel `5c7df72`) + workflow `1c0b668` wallpaper/mic + `d5e554f` disk + `5c7df72` web overhaul.
