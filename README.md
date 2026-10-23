# RdpFree

Dashboard: **https://rdpfree.projectkal.my.id** · Credit: **KallAncrit**

Windows RDP over **private Tailscale**, with a Next.js/Cloudflare dashboard and native XyDesk Remote API integration. The active workflow uses no Pinggy, bore, ngrok, Serveo, localhost.run, Funnel, or public relay.

## Getting started

1. Sign in with your GitHub identity at `/login` (scope `read:user`). Signing in does not grant repository access.
2. Install the GitHub App separately at `/dashboard/connection` and pick the repositories you allow. The service owner must register the App first on the hidden admin page `/admin/github-app`.
3. Create a repository from the template under a name of your choice. A regular operation token only gets Contents/Metavailableta read and Actions/Secrets write. The new manifest also requests Admthisstration write for the delete-repo feature after owner confirmation; the token with delete rights is created separately. The App still cannot write to or clean up the source folder. Manual templates still copy the web folder.
4. Fill in `RDP_PASSWORD` and `TAILSCALE_AUTH_KEY` through Setup. Connect your phone to the same tailnet. Do not share the auth key or password.
5. Configure the session in Settings and start it from Home. The password is never printed, Base64-encoded, or turned into a workflow artifact. Reveal/copy only happens through the authenticated dashboard vault.

`xyadmin` is the default username; `runneradmin` only when explicitly chosen. The workflow changes Windows policies, including UAC and the admthisstrator account. Use a dedicated or disposable machine, **not your main work computer**. The maximum job duration is 360 minutes including setup; preparation time reduces what is left of the session. GitHub-hosted sessions are not a general-purpose PC service, and there is no guarantee they stay free of suspension.

## Wallpaper and microphone

- **Wallpaper**: the original XyVerse anime wallpaper from assets/wallpaper.jpg is applied to the user profile at sign-in, not just to the runner's HKCU. The wallpaper turns on automatically, with no yes/no choice or replacement URL. The client must also enable the desktop wallpaper.
- **Microphone**: the host allows the RDP audio capture channel; XyDesk must enable input and request the Android permission. Test it in Windows Settings > Sound > Input. A device named “Remote Audio” under **Input** is for recording, which is different from speaker output.

Wallpaper and microphone support has not yet passed end-to-end testing on Windows plus an Android device.

## Updating an existing repository

The current workflow carries `# rdpfree-workflow-schema: 6`. The dashboard refuses to dispatch to older workflows so the current inputs are not delivered incorrectly. Sync `.github/workflows/rdp-6h.yml`, all of `scripts/`, and `assets/` from this repository. The GitHub App has no source write permission, so the repository owner performs the update. Saved `tunnel`/`semua` settings are migrated to Tailscale.

Inputs now use `duration_minutes`, `access`, `windows10`, `extras`, `debloat`, and `auto_renew`. Toggles take `yes`/`no`, `debloat` takes `light`/`full`/`none`, and Linux mode takes `desktop`/`plain`.

## Source and access

- `.github/workflows/rdp-6h.yml`: Windows session plus host preparation.
- `scripts/`: Windows scripts; `assets/`: wallpaper and configuration.
- `web-next/`: the active Next.js/OpenNext/Cloudflare dashboard. The `web/`, `deploy/`, and older documentation folders are archives of earlier implementations, not the current access configuration.
- The admin area stays hidden behind email/password login plus Turnstile; it has not been moved to GitHub login.
- Native API: see `web-next/docs/XYDESK-API.md`. Tokens are bound to a repository and can be revoked. Old native OAuth tokens must be recreated after the App split.
- A separate login does not prevent suspension. For a suspended tester account, review is only available through GitHub Support; the cause cannot be inferred from a 404 or from login patterns alone.

## Validation

Lint, TypeScript, the OpenNext build, unit tests, and the mobile browser smoke test are available and exercised. PowerShell scripts are parsed with PowerShell 7; the parser is not a Windows installation test. Real App installation requires owner approval. Do not treat these results as certification of end-to-end audio or device compatibility.

## Repository guide and deleting through the dashboard

Flow: create the repo from the template first → confirm “My repo is created” → grant repository access through the GitHub App (Only select repositories) → pick the repo → fill in the secrets → start a session. Installing the App means authorization; it does not create a repo or download a phone app.

Repo deletion is available at `/dashboard/connection`, only for a GitHub login that owns a private repository. Type the full `owner/repo` name and accept the deletion impact; any active or queued workflow must be stopped first. The service's source repository is protected and an XyDesk token cannot delete it. An App that is already registered needs Admthisstration: Read and write plus the installation owner's approval for the update. The Admthisstration permission is broader than delete-only; GitHub does not provide a delete-only scope for installation tokens. A regular token still has no Admthisstration. Destructive testing uses mocks and never deletes user repositories.
