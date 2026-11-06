# Sailuo

Dashboard: **https://sailuo.projectkal.my.id** · Credit: ****

Windows RDP over **private Tailscale**, with a Next.js/Cloudflare dashboard and native Sailuo Remote API integration. The active workflow uses no Pinggy, bore, ngrok, Serveo, localhost.run, Funnel, or public relay.

## Getting started

1. Sign in with your GitHub identity at `/login` (scope `read:user`). Signing in does not grant repository access.
2. Install the GitHub App separately at `/dashboard/connection` and pick the repositories you allow. The service owner must register the App first on the hidden admin page `/admin/github-app`.
3. Create a repository from the template under a name of your choice. A regular operation token only gets Contents/Metadata read and Actions/Secrets write. The new manifest also requests Administration write for the delete-repo feature after owner confirmation; the token with delete rights is created separately. The App still cannot write to or clean up the source folder. Manual templates still copy the web folder.
4. Fill in `RDP_PASSWORD` and `TAILSCALE_AUTH_KEY` through Setup. Connect your phone to the same tailnet. Do not share the auth key or password.
5. Configure the session in Settings and start it from Home. The password is never printed, Base64-encoded, or turned into a workflow artifact. Reveal/copy only happens through the authenticated dashboard vault.

`xyadmin` is the default username; `runneradmin` only when explicitly chosen. The workflow changes Windows policies, including UAC and the administrator account. Use a dedicated or disposable machine, **not your main work computer**. The maximum job duration is 360 minutes including setup; preparation time reduces what is left of the session. GitHub-hosted sessions are not a general-purpose PC service, and there is no guarantee they stay free of suspension.

## Wallpaper, microphone, and screen recording

- **Wallpaper**: the original Sailuo anime wallpaper from assets/wallpaper.jpg is applied to the user profile at sign-in, not just to the runner's HKCU. The wallpaper turns on automatically, with no yes/no choice or replacement URL. The client must also enable the desktop wallpaper.
- **Microphone**: the host allows the RDP audio-capture channel. The RDP client must enable microphone/input redirection and the Android client must have microphone permission. In the VM, check **Dashboard > System > Screen recording > Check RDP microphone** or Windows Settings > Sound > Input for **Remote Audio**.
- **Screen recording**: start and stop it manually from **Dashboard > System > Screen recording**. The combined option records the visible VM desktop and the redirected RDP microphone; the screen-only option records no audio. FFmpeg 9.0.2 Essentials is downloaded on first use and SHA-256 verified. MP4 files are saved to the signed-in user's `Videos\SailuoRecordings` folder. Nothing is uploaded automatically, closing the Dashboard stops recording, and capture also stops before VM disk free space falls below 2 GB.

These microphone and recording paths still require end-to-end testing with a Windows VM and the actual RDP client. GitHub-hosted VMs are temporary; copy recordings off the VM before the session ends if you need to keep them.

## Updating an existing repository

The current workflow carries `# sailuo-workflow-schema: 6`. The dashboard refuses to dispatch to older workflows so the current inputs are not delivered incorrectly. Sync `.github/workflows/rdp-6h.yml`, all of `scripts/`, and `assets/` from this repository. The GitHub App has no source write permission, so the repository owner performs the update. Saved `tunnel`/`semua` settings are migrated to Tailscale.

Inputs now use `duration_minutes`, `access`, `windows10`, `extras`, `debloat`, and `auto_renew`. Toggles take `yes`/`no`, `debloat` takes `light`/`full`/`none`, and Linux mode takes `desktop`/`plain`.

## Source and access

- `.github/workflows/rdp-6h.yml`: Windows session plus host preparation.
- `scripts/`: Windows scripts; `assets/`: wallpaper and configuration.
- The dashboard is no longer bundled in this repository; host it separately if needed.
- Native API documentation has been removed along with the dashboard. Tokens are bound to a repository and can be revoked.
- A separate login does not prevent suspension. For a suspended tester account, review is only available through GitHub Support; the cause cannot be inferred from a 404 or from login patterns alone.

## Validation

PowerShell scripts are parsed with PowerShell 7; the parser is not a Windows installation test. Real App installation requires owner approval. Do not treat these results as certification of end-to-end audio or device compatibility.
