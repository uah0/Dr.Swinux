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
Windows 32-bit: explicitly out of scope; do not support
Linux:          planned
Android:        planned
```

**Project decision (2026-09-03): 32-bit Windows systems are excluded from Dr.Swinux support.** Do not spend development effort on an x86 Codex build, x86 agent backend, compatibility layer, or other work intended to make Dr.Swinux operate on 32-bit Windows. The explicit early architecture guard introduced in v1.5.35 should remain so users receive a clear unsupported-platform message.

A real 2026-09-03 test proved that a 32-bit Windows installation cannot run the current pinned Windows Codex runtime. This finding is retained as evidence for the guard, but it is no longer a capability gap to solve. Windows development targets 64-bit systems.

## 5. Safety invariants

Codex remains unelevated. Intended baseline includes:

```text
approval_policy="never"
windows.sandbox="unelevated"
--sandbox workspace-write
```

Do not introduce unrestricted full-access Codex execution.

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
Dr.Swinux v1.5.36-final
Tag: v1.5.36
Release target commit: dbb43aec90ff45002d7ed23150ba65c8a3835227
Asset: Dr.Swinux-v1.5.36-final.zip
SHA-256: 37ebbaa21a7e3ec2d82a2ce38d5a699bf35395f81b437e32089108386ac829cf
GitHub Actions run: 33741965678
```

Source audit, portable ZIP build, ZIP verification and GitHub Release publication passed.

The first v1.5.36 audit attempt (run `33741830466`) correctly failed because a new explanatory comment literally contained the forbidden full-access sandbox token. That was an audit-rule false positive against wording, not a runtime safety regression. The comment was rewritten without the forbidden token and the full release audit was rerun successfully.

The canonical runtime version is read from `system/VERSION.txt`. Do not hardcode the current version into `Start-Agent.ps1`.

## 8. Real Windows startup/runtime findings

The earlier `Z:\Dr.Swinux\` startup sequence established:

1. Initial launcher reached `START_AGENT_BEGIN` and returned native exit code `216` without useful diagnostic detail.
2. v1.5.33 added executable probes and proved the existing portable `pwsh.exe` was incompatible with that Windows installation. The launcher correctly routed to bootstrap repair.
3. Bootstrap selected `PowerShell-7.6.5-win-x86.zip`, proving the tested Windows installation itself was 32-bit. Windows PowerShell 5.1 initially failed the GitHub download because it could not establish the SSL/TLS channel; v1.5.34 explicitly enabled TLS 1.2 and the repair then succeeded.
4. After x86 PowerShell 7.6.5 started successfully, startup advanced into Codex preparation and failed because the setup only uses official Codex Windows x86_64 assets. v1.5.35 added an explicit 32-bit Windows guard.
5. Project decision: 32-bit Windows is excluded from Dr.Swinux support.

A later real task on a supported 64-bit Windows machine exposed a separate generic execution-boundary defect. User task: **`установи хром`**. PowerShell, Codex 0.151.0, ChatGPT auth and the elevated Broker all reached READY. Codex then tried `GetInstalledPackages`/`SearchPackage`, but every local process launch failed before Broker execution with:

```text
windows unelevated restricted-token sandbox cannot enforce split writable root sets directly; refusing to run unsandboxed
```

Codex retried with portable PowerShell, a simpler PowerShell invocation and `cmd.exe`; all failed at the same CreateProcess sandbox boundary. This is evidence that the task-specific Chrome path was not the defect: the agent could not execute any local tool.

Codex source inspection confirmed the Windows restricted-token backend deliberately fails closed when the managed permission profile's writable-root set differs from the legacy workspace-write projection. The default workspace-write configuration may add generic temp roots in addition to the working directory.

v1.5.36 fixes this generically without elevating Codex or bypassing the sandbox. Dr.Swinux's portable Codex config now sets:

```text
[sandbox_workspace_write]
exclude_tmpdir_env_var = true
exclude_slash_tmp = true
```

Dr.Swinux only needs the current report session writable; privileged/state-changing actions continue through Broker. `Start-DoctorSwinux.ps1` rewrites the canonical portable config on every launch so already-installed runtimes receive the fix, and `Setup-PortableCodex.ps1` writes the same config so a first-time/repaired Codex setup cannot overwrite it back to the failing defaults.

Important lessons: executable existence is not executability; bootstrap must not rely on legacy TLS defaults; unsupported platform/runtime combinations must be detected early; and an agent/tool orchestration layer must ensure the sandbox can launch its own allowed local tools while remaining unelevated.

## 9. Mandatory audit process

After every code change, audit before handing over a build. Repeat until clean.

If an audit finds a real defect, fix it and rerun. If an audit rule is false-positive/obsolete, fix the rule or offending wording as appropriate and rerun the complete relevant audit.

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

## 10. Codex/auth/sandbox baseline

Pinned Codex CLI: **0.151.0** (`rust-v0.151.0`). Do not casually bump; 0.152.0 previously caused device-auth problems in real testing.

Auth baseline:

- normal `codex login` browser OAuth;
- `codex login status` confirmation;
- no copying host `auth.json`;
- no token inspection/logging;
- clear inherited process-only `CODEX_ACCESS_TOKEN` / `OPENAI_API_KEY`;
- portable `CODEX_HOME`.

Canonical portable config baseline:

```text
cli_auth_credentials_store = "file"
forced_login_method = "chatgpt"

[sandbox_workspace_write]
exclude_tmpdir_env_var = true
exclude_slash_tmp = true
```

Do not remove the two workspace-write exclusion settings unless newer real Windows evidence shows a safe replacement. They are part of the current fix that keeps the unelevated restricted-token sandbox's writable roots compatible with Dr.Swinux's report-session workspace.

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

The Chrome installation task is now the acceptance test for v1.5.36's sandbox repair. Re-run the **exact same original task `установи хром`**. Do not add hints or task-specific logic. Success requires Codex to be able to invoke the typed package Broker actions, reach the user's confirmation when installation is justified, and verify the installed state afterward.

## 14. LAB MODE

v1.5.32 introduced LAB MODE (`system/Lab-Loop.ps1`, `system/Audit-LabCandidate.ps1`, `system/LAB-SWINUX.cmd`). It uses real tasks, isolated candidate self-modification, guarded audit and retry of the same original task. Safety/Broker/update/auth boundaries are protected from autonomous rewriting.

Full Lab runtime still requires real Windows testing.

## 15. Next real development/test step

On the same supported 64-bit Windows machine that produced the sandbox failure, update/run **v1.5.36** and retry exactly:

> `установи хром`

Preserve the new report session. The expected first proof is that a local `broker-tool.ps1` invocation now actually launches instead of failing at CreateProcess with the split-writable-roots error. Then observe whether Codex correctly performs package discovery, confirmation-gated installation and post-install verification.

If the same sandbox error remains, do not weaken sandboxing or bypass Broker. Inspect the new Codex log and the effective sandbox roots/config, then patch only the remaining generic mismatch. If the task advances to a different failure, treat that as the next real development signal.

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

**Windows x86 support is not on the roadmap.**

## 17. New-chat continuation

Use:

> Continue development of Dr.Swinux. Read `DR-SWINUX-HANDOFF.md` and the current repository before changing anything. Treat the repository as source of truth for code and this handoff as source of truth for project decisions/history unless newer real test evidence supersedes it. After every code change, audit and iterate until clean.

Git records what changed. This file records what the next development conversation must know and why.
