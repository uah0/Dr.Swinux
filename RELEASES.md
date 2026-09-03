# Publishing Dr.Swinux releases

Deployable releases are published by GitHub Actions from `uah0/Dr.Swinux`.

The canonical version is stored in `system/VERSION.txt`. The release workflow audits PowerShell syntax, safety/update regressions, platform manifests, branding assets, shortcut/icon generation, package layout and SHA-256 before publishing.

Current release naming:

- `Dr.Swinux-vX.Y.Z-final.zip` — portable Dr.Swinux package;
- `Dr.Swinux-vX.Y.Z-final.zip.sha256` — published SHA-256 checksum.

The updater prefers Dr.Swinux-named assets and verifies the GitHub `asset.digest` SHA-256 before installation. Transitional legacy package names may remain recognized internally for compatibility with older installed builds, but public release branding is **Dr.Swinux**.

Never package `tools/CodexHome`, `reports`, `auth.json`, prompt history, or local logs from a developer machine.
