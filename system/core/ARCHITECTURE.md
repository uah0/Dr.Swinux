# Doctor Swinux cross-platform architecture

Doctor Swinux is one portable AI engineer with a shared core and platform adapters. The current production platform is Windows. Linux and Android are represented explicitly in the architecture, but are not yet advertised as working runtimes.

## Invariants owned by the core

The core owns platform-independent behavior:

- natural-language task intake;
- autonomous hypothesis -> observation -> decision -> action -> verification loop;
- task history and reports;
- Codex session lifecycle and result handling;
- safety contract: the AI process itself stays unprivileged;
- privileged operations are exposed only through typed, allowlisted broker actions;
- every state-changing action must be verified against the user's original goal;
- new capabilities are added because real tasks expose a concrete evidence/action gap, not because hypothetical workflows are invented.

## Platform boundary

Each platform lives under `system/platform/<id>/` and owns only OS-specific details: launcher, runtime/bootstrap, local evidence providers, package manager integration, privileged broker implementation, and platform-specific confirmations.

Every platform has a `manifest.json` conforming to `system/core/platform.schema.json`. `system/core/Get-PlatformManifest.ps1` identifies the current OS and resolves the corresponding manifest without embedding platform-specific paths in the core.

## Rename compatibility boundary

The public product name is **Doctor Swinux**. Proven Windows internals may temporarily keep `Dr.Swintus` filenames, log names, version prefix, and updater repository coordinates so installed copies can upgrade safely through the rename. Those are compatibility identifiers, not the product brand.

The repository endpoint is deliberately not changed until the repository itself is renamed and the new exact path is verified. The release asset name also remains compatible during this transition so v1.5.27 and earlier updaters can discover the next package.

## Migration rule

The proven Windows runtime is not moved wholesale just to make the tree look cleaner. Existing Windows entrypoints remain in their proven locations unless a real task requires touching that area and the move can be audited without changing behavior.

## Target layout

```text
Doctor-Swinux/
  system/
    core/
    platform/
      windows/
      linux/
      android/
    assets/branding/
```

Windows remains the reference implementation until its autonomous loop and broker model have been exercised on enough real machines/tasks. Linux should be the next runtime; Android follows with its own permission/Shizuku model.
