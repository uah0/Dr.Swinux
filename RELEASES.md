# Publishing Doctor Swinux releases

Deployable releases are published by GitHub Actions from `uah0/Dr.Swinux`.

The canonical version remains in `system/VERSION.txt`. The release workflow audits PowerShell syntax, safety/update regressions, platform manifests, branding assets, shortcut/icon generation, package layout and SHA-256 before publishing.

During the repository/product rename bridge, v1.5.29 publishes both:

- `Doctor.Swinux-vX.Y.Z-final.zip` — normal Doctor Swinux package;
- `Dr.Swintus-vX.Y.Z-final.zip` — compatibility package for already-installed transition builds.

The updater in v1.5.29 prefers the Doctor Swinux package and accepts either package root while verifying the GitHub `asset.digest` SHA-256.

Never package `tools/CodexHome`, `reports`, `auth.json`, prompt history, or local logs from a developer machine.
