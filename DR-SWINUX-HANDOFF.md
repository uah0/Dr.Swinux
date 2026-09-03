# Dr.Swinux — project handoff

> Persistent context for continuing development in a new ChatGPT conversation.
>
> Update this file when architecture, safety, release baseline, real-machine findings, development process, or the next real test materially changes.

Last updated: 2026-09-03

## 1. Product identity

**Dr.Swinux** is a portable AI doctor for computers and an **orchestrator for the Codex agent**. It is not an engineer and it does not develop AI systems.

- **Codex is the agent and intelligence.** It reasons, forms hypotheses, interprets evidence and decides the next useful observation/action.
- **Dr.Swinux is the orchestrator.** It maintains task/session context for the current computer, exposes platform capabilities, routes execution, owns the safety/privilege boundary, records results and keeps the loop tied to verification of the original user goal.
- **Platform tools are the senses and hands.** Windows currently uses PowerShell/WMI/CIM/Event Log/winget and the typed Broker.
- **Broker is the controlled privileged execution boundary.** Codex remains unelevated.

Canonical formulation:

> **Dr.Swinux is a portable orchestrator that turns the general Codex agent into the autonomous doctor of a particular computer.**

## 2. Fundamental development rule

Do not invent narrow workflows. Real user tasks drive development.

```text
real task
  -> autonomous attempt
  -> solved: record result
  -> blocked: classify the actual gap
  -> make the smallest generic improvement
  -> audit
  -> reproduce the same initial state where possible
  -> run the SAME original task again
```

Do not make retries easier by rewriting the user's task with hints.

## 3. Product value above plain Codex

Dr.Swinux must not become only a launcher plus scripts. Its product layer is:

- portable orchestration environment;
- task/session lifecycle and current-machine context;
- structured OS observations/actions;
- reusable capabilities discovered through real work;
- privilege separation and confirmation policy;
- symptom/goal -> hypotheses -> evidence -> action -> verification loop;
- reports and longitudinal machine/case history;
- platform adapters.

## 4. Platform strategy

Current status:

```text
Windows 64-bit: supported reference implementation
Windows 32-bit: unsupported by the current Codex runtime
Linux:          planned
Android:        planned
```

A real 2026-09-03 test proved that a 32-bit Windows installation cannot run the current pinned Windows Codex runtime. Dr.Swinux v1.5.35 detects this explicitly and reports a concrete platform blocker instead of proceeding into an opaque Codex/native-loader failure.

The current `Setup-PortableCodex.ps1` installs pinned Codex `0.151.0` from official Windows **x86_64** assets. Do not claim Windows x86 support unless a real compatible Codex runtime exists and passes startup/auth/task testing.

## 5. Safety invariants

Codex remains unelevated. Intended baseline includes:

```text
approval_policy="never"
windows.sandbox="unelevated"
--sandbox workspace-write
```

Do not introduce `danger-full-access`.

Privileged actions go only through the typed allowlisted Broker. UAC remains real Windows consent. Do not add an arbitrary elevated shell/script facility.

Critical/destructive/security-sensitive operations remain denied or explicitly gated. Do not silently enable formatting/partitioning, BCD/BitLocker changes, user deletion, security disabling, mass deletion, startup persistence creation, etc. DISM/SFC remain disabled unless explicitly reconsidered.

Self-modification must not weaken the Broker/safety boundary.

## 6. Layout and branding

Conceptual package layout:

```text
Dr.Swinux/
  ASK-AGENT.cmd.lnk
  README.md
  DR-SWINUX-HANDOFF.md
  tools/
    Codex/
    CodexHome/
    PowerShell/
  system/
    ASK-AGENT.cmd
    LAB-SWINUX.cmd
    Start-Agent.ps1
    Start-DoctorSwinux.ps1
    Update-DrSwintus.ps1
    Lab-Loop.ps1
    Audit-LabCandidate.ps1
    core/
    platform/
    assets/branding/
  reports/
```

Legacy internal filenames may remain for compatibility. Public branding is **Dr.Swinux**. Do not use `Doctor Swinux`, `DOCTOR SWINUX`, or describe the product as an engineer.

`RUN-DR-SWINTUS.cmd` must not return.

## 7. Current release baseline

Repository: `uah0/Dr.Swinux`

Current stable release:

```text
Dr.Swinux v1.5.35-final
Tag: v1.5.35
Release target commit: f5315cfc0a3c4f38b06402ac4912d9158b0ec6e7
Asset: Dr.Swinux-v1.5.35-final.zip
SHA-256: b2dbf5ba04671840e5e45d72ac3dc17ffd900dcb26988fc167f57007a35e76f4
GitHub Actions run: 33735823383
```

The run completed successfully through source audit, portable ZIP build, ZIP verification and GitHub Release publication.

The canonical runtime version is read from `system/VERSION.txt`. Do not hardcode the current version into `Start-Agent.ps1`.

## 8. Startup-failure history from real Windows testing

The same `Z:\Dr.Swinux\` test sequence exposed three distinct real conditions:

1. Initial launcher reached `START_AGENT_BEGIN` and returned native exit code `216` without useful diagnostic detail.
2. v1.5.33 added executable probes and proved the existing portable `pwsh.exe` was incompatible with that Windows installation. The launcher correctly routed to bootstrap repair.
3. Bootstrap selected `PowerShell-7.6.5-win-x86.zip`, proving the tested Windows installation itself is 32-bit. Windows PowerShell 5.1 initially failed the GitHub download because it could not establish the SSL/TLS channel; v1.5.34 explicitly enabled TLS 1.2 and the repair then succeeded.
4. After x86 PowerShell 7.6.5 started successfully, startup advanced into Codex preparation and failed in `Start-Agent.ps1` while invoking `Setup-PortableCodex.ps1`. The setup code only uses official Codex Windows x86_64 assets. This established the actual platform blocker: **the tested Windows installation is 32-bit and cannot run the current Codex runtime.**
5. v1.5.35 adds an explicit early 32-bit-Windows guard in `Start-DoctorSwinux.ps1`, so this condition now produces a clear supported-platform message instead of an opaque `ScriptHalted`/native failure.

Important lessons: executable existence is not executability; bootstrap must not rely on legacy TLS defaults; and Dr.Swinux must detect unsupported platform/runtime combinations before attempting the agent.

## 9. Mandatory audit process

After every code change, audit before handing over a build. Repeat until clean.

If an audit finds a real defect, fix it and rerun. If an audit rule is false-positive/obsolete, fix the rule and rerun the complete relevant audit.

Mandatory regression scans include at least:

```text
=\s*try\s*\{
```

and unsafe interpolated `$variable:` forms except valid PowerShell scopes.

Historical path regression must not return:

```text
NO: -RootPath "%ROOT%"
NO: -UsbRoot "%USBROOT%"
```

Do not pass root paths ending in backslash through CMD to PowerShell.

## 10. Codex/auth baseline

Pinned Codex CLI: **0.151.0** (`rust-v0.151.0`). Do not casually bump; 0.152.0 previously caused device-auth problems in real testing.

Auth baseline:

- normal `codex login` browser OAuth;
- `codex login status` confirmation;
- no copying host `auth.json`;
- no token inspection/logging;
- clear inherited process-only `CODEX_ACCESS_TOKEN` / `OPENAI_API_KEY`;
- portable `CODEX_HOME`.

Config baseline:

```text
cli_auth_credentials_store = "file"
forced_login_method = "chatgpt"
```

## 11. Updater lifecycle

Updater checks before the first task prompt. Successful install exits code `23`; `system/ASK-AGENT.cmd` restarts the agent in the same console. `SingleTask` skips updater. Release asset SHA-256 is verified.

## 12. Broker baseline

Known read capabilities:

1. GetWifiDetails
2. GetNetworkExtended
3. GetProcessExtended
4. GetDriverInventory
5. GetDeviceInventory
6. GetServiceExtended
7. GetStorageExtended
8. GetStorageReliability
9. GetEventLogElevated
10. GetUpdateHistory
11. GetFirewallSecurityStatus
12. GetScheduledTaskSnapshot
13. GetRegistryRead
14. GetInstalledPackages
15. SearchPackage

Known confirmed writes:

16. InstallPackage
17. UninstallPackage
18. SetRegistryValue
19. RemoveRegistryValue

No arbitrary elevated command/script parameter.

## 13. Proven real-task behavior

Real tasks have already demonstrated generic reasoning for Wi-Fi inspection, crash diagnosis, filling C: drive investigation, winget installs, Explorer hidden-files setting, startup removal, firewall port inspection and a slow external-drive investigation.

Do not hardcode those cases as workflows.

The slow external-drive case also exposed a genuine missing controlled filesystem-repair capability. Do not implement repair blindly; it must be typed, constrained, confirmation-gated, backup-aware and followed by verification if/when the real task is resumed.

## 14. LAB MODE

v1.5.32 introduced LAB MODE (`system/Lab-Loop.ps1`, `system/Audit-LabCandidate.ps1`, `system/LAB-SWINUX.cmd`). It uses real tasks, isolated candidate self-modification, guarded audit and retry of the same original task. Safety/Broker/update/auth boundaries are protected from autonomous rewriting.

Full Lab runtime still requires real Windows testing.

## 15. Next real development/test step

**Do not continue testing this current 32-bit Windows installation as a supported Dr.Swinux target.** It has now supplied the useful evidence: current Codex runtime support is blocked by OS architecture.

Create/reinstall the VM with **64-bit Windows 10** (or another supported 64-bit Windows environment), take a clean snapshot, then run the current release and continue with the same ordinary-language autonomous testing process.

On that 64-bit VM, first prove clean startup/bootstrap/auth. Then return to real tasks. If a new failure occurs, preserve the exact task, snapshot/state and Dr.Swinux logs, patch only the real failing stage, audit, restore/reproduce and retry the same original task.

## 16. Longer roadmap

1. Prove the autonomous doctor loop across varied real Windows 64-bit tasks.
2. Make observations/actions increasingly capability-driven where real tasks justify it.
3. Close action -> verification.
4. Build a structured local machine/case record.
5. Use recorded capability gaps to drive self-extension.
6. Harden portability across unfamiliar Windows 64-bit machines/removable media.
7. Extract only proven cross-platform abstractions.
8. Implement/test Linux adapter.
9. Implement/test Android runtime.

## 17. New-chat continuation

Use:

> Continue development of Dr.Swinux. Read `DR-SWINUX-HANDOFF.md` and the current repository before changing anything. Treat the repository as source of truth for code and this handoff as source of truth for project decisions/history unless newer real test evidence supersedes it. After every code change, audit and iterate until clean.

Git records what changed. This file records what the next development conversation must know and why.
