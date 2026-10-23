# Creating or updating an RdpFree repository

Credit: KallAncrit. Follow the [active README](README.md).

1. Use the `xykal/XyRDP` template with a repository name of your choice.
2. Enable Actions, then fill in `RDP_PASSWORD` and `TAILSCALE_AUTH_KEY` in Actions secrets or through dashboard Setup.
3. Access is Tailscale only. Sign your phone or PC in to the same tailnet and allow TCP 3389 in the tailnet ACL.
4. Choose the settings (`duration_minutes`, `access`, `windows10`, `extras`, `debloat`, `auto_renew`) and start a session. Never print or store the password as a public artifact.

Older repositories need to sync the schema 6 workflow, scripts, and assets together. The App only has source read permission, so it cannot update those files automatically. A manual template also copies the web folder; owners may delete `web`, `web-next`, and `deploy` from the session repository if they are not needed.

GitHub login identity and GitHub App authorization are two separate processes. App approval/installation only covers the repositories you select. There is no anti-suspension guarantee or universal VM support.
