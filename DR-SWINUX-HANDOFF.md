# Dr.Swinux — project handoff

> Persistent context for continuing development in a new ChatGPT conversation.
>
> **Maintenance rule:** update this file whenever an architectural decision, safety invariant, release baseline, real-machine finding, or development-process rule changes. Do not use it as a changelog for insignificant edits.

Last updated: 2026-09-03

## 1. Product identity and goal

**Dr.Swinux** is a portable AI doctor for computers and an **orchestrator for the Codex agent**. It is not an AI engineer and it does not develop AI systems.

The architectural identity is explicit:

- **Codex is the agent and intelligence.** It reasons, forms hypotheses, interprets evidence and decides what observation or action is useful next.
- **Dr.Swinux is the orchestrator.** It creates and maintains the task/session context, provides Codex with the capabilities and relevant context of the current computer, routes execution through the appropriate platform mechanisms, enforces the privilege/safety boundary, records results and keeps the task tied to verification of the user's original goal.
- **Platform tools are the senses and hands.** Windows currently provides PowerShell/WMI/CIM/Event Log/winget and the typed Broker; future platforms provide their own adapters.
- **The Broker is the controlled privileged execution boundary.** Codex itself remains unelevated.

Canonical product formulation:

> **Dr.Swinux is a portable orchestrator that turns the general Codex agent into the autonomous doctor of a particular computer.**

Codex is therefore not Dr.Swinux itself. Conversely, Dr.Swinux must not become merely a launcher/wrapper around Codex. Its product value is the orchestration layer above the agent: machine context, capabilities, lifecycle, execution policy, verification and longitudinal machine/case history.

Target user experience:

```text
ordinary-language task
  -> Dr.Swinux starts and maintains the task context on this computer
  -> Codex forms hypotheses
  -> Codex chooses the smallest useful observation
  -> Dr.Swinux exposes/routes the appropriate local capability
  -> evidence returns to Codex
  -> Codex confirms/rejects/refines hypotheses
  -> Dr.Swinux routes an allowed action when justified
  -> result returns to Codex
  -> Dr.Swinux keeps the loop tied to verification of the original goal
  -> continue until solved or a concrete blocker is identified
```

The user should normally describe the goal once rather than manually guide the doctor through diagnostic commands.

## 2. Fundamental development rule

Do not build Dr.Swinux around invented narrow workflows.

**Real tasks drive development.** Tools/capabilities are created or improved when a real task exposes a missing observation, action, verification mechanism, reasoning/tool-discovery problem, orchestration problem, or platform limitation.

Preferred development cycle:

```text
real task
  -> autonomous orchestrated attempt
  -> solved: record result
  -> blocked: classify the actual gap
  -> make the smallest generic improvement
  -> audit
  -> reproduce the same initial state where possible
  -> run the SAME original task again
```

Do not make the retry easier by rewriting the user's task with diagnostic hints. Otherwise it is impossible to distinguish an improved Dr.Swinux from improved prompting by the developer.

## 3. Orchestrator model vs. plain Codex

If Dr.Swinux becomes only a Codex launcher plus PowerShell scripts, it has little fundamental value over launching Codex directly.

The product layer above Codex should provide:

- a portable ready-to-run orchestration environment;
- task/session lifecycle and machine context;
- standardized, structured OS observation;
- reusable capabilities rather than task-specific workflows;
- controlled privilege separation;
- autonomous symptom/goal -> hypotheses -> evidence -> action -> verification behavior;
- reports and structured case history;
- eventually a longitudinal local record of the particular computer;
- platform adapters for Windows, Linux, and Android rather than pretending all operating systems expose the same mechanisms.

The strongest long-term differentiator may be longitudinal knowledge of a particular machine: hardware, OS, drivers, installed software, storage/network/services/updates, previous symptoms, investigations, changes, reasons for changes, and verification results. Dr.Swinux should make relevant history available to Codex as context while keeping prior conclusions as evidence rather than dogma.

## 4. Platform strategy

Current status:

```text
Windows: supported
Linux:   planned
Android: planned
```

Windows is the reference implementation and must be exercised on enough real tasks before aggressively extracting abstractions.

Common/core orchestration concepts:

- natural-language task lifecycle;
- Codex agent lifecycle;
- autonomous reasoning loop coordination;
- capability contracts/discovery;
- evidence/history model;
- result and verification semantics;
- machine/session context.

Platform-specific concepts belong behind adapters:

- Windows: Broker, winget, WMI/CIM, Event Log, Windows services/settings/etc.;
- Linux future: sudo broker, apt/dnf/pacman, /proc, /sys, systemd/journal, nmcli, lsblk, smartctl, lspci, ip, ss, etc.;
- Android future: Android APIs and platform-specific privilege model, optionally extended by mechanisms such as Shizuku/root where appropriate.

**Migration rule:** do not move proven Windows runtime wholesale merely to make the directory tree cleaner. Move behavior behind a platform boundary when a real task requires touching that area and the move can be audited without changing proven behavior.

## 5. Safety architecture — invariants

Reasoning authority and privileged execution authority are deliberately separated.

Codex itself remains **unelevated**. Current intended execution invariants include:

```text
approval_policy="never"
windows.sandbox="unelevated"
--sandbox workspace-write
```

Do not introduce `danger-full-access`.

Dr.Swinux owns/orchestrates the execution boundary. Privileged operations go through the elevated **typed allowlisted Broker**. UAC remains real Windows consent. Do not hide or bypass it.

Do not add an arbitrary unrestricted elevated command/script facility.

Critical/destructive/security-sensitive operations remain denied or require explicit policy/confirmation. Examples that must not silently become autonomous include disk formatting/partition changes, BCD changes, BitLocker changes, deleting users, disabling security, mass deletion, or startup persistence mechanisms.

DISM/SFC remain disabled unless explicitly reconsidered.

Self-modification must not be allowed to rewrite the safety boundary merely because a task is blocked. Dr.Swinux may develop new senses/hands, but it must not autonomously remove confirmation, grant Codex an elevated shell, disable audits/deny rules, or turn the Broker into arbitrary command execution.

## 6. Current portable layout and compatibility

Current conceptual package layout:

```text
Dr.Swinux/
  ASK-AGENT.cmd.lnk
  LAB-SWINUX.cmd
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

Some legacy internal filenames remain intentionally for compatibility, including `Start-Agent.ps1`, `Start-DoctorSwinux.ps1`, and `Update-DrSwintus.ps1`. Public branding is **Dr.Swinux**.

`RUN-DR-SWINTUS.cmd` was removed and must not return.

The root `ASK-AGENT.cmd.lnk` targets `system/ASK-AGENT.cmd`.

## 7. Branding rules

Final public name: **Dr.Swinux**.

Do not use `Doctor Swinux`, `DOCTOR SWINUX`, or describe the product as an engineer.

Public concept: doctor. Architectural role: orchestrator for the Codex agent.

Current branding assets are under `system/assets/branding/` and include:

- `dr-swinux.png`
- `dr-swinux-icon.png`
- `dr-swinux.ico`

There is also a root `Dr.Swinux.png` used by README.

Known technical debt: inspect `Create-Shortcut.ps1` before claiming the repository-supplied `.ico` survives packaging byte-for-byte. Historically the shortcut script regenerated/overwrote the ICO from the icon PNG.

## 8. GitHub repository and release baseline

Repository:

`uah0/Dr.Swinux`

Repository URL:

`https://github.com/uah0/Dr.Swinux`

The repository was deliberately recreated on 2026-09-02 as a clean repository because the previous Git history and releases were no longer required. The current repository history is the new source of truth; old repository commit IDs and old release hashes must not be used as the current baseline.

Current release baseline:

```text
Dr.Swinux v1.5.32-final
Tag: v1.5.32
Release target commit: 2d9fcbb6cf91e005345b55d4efc2e8046478275a
Asset: Dr.Swinux-v1.5.32-final.zip
SHA-256: 1396e33807a67c278f753d3ee3f65bf97e1ef36b95620d35cdebc87bf0994d48
```

The release workflow for this clean baseline completed successfully through source audit, portable ZIP build, ZIP verification, and GitHub Release publication.

The canonical runtime version is read from `system/VERSION.txt`. Do not hardcode the current version into `Start-Agent.ps1`.

Legacy internal filenames may remain for compatibility, but do not reintroduce old public branding. The obsolete `.mailmap` from the previous-history cleanup was removed after the repository was recreated; it is not needed for the clean history.

## 9. Mandatory development/audit process

**After every code change, audit before handing over a build. Repeat as many iterations as required.**

If an audit reports a real product defect: fix the defect and rerun.

If an audit reports a false positive caused by an obsolete/incorrect audit rule: fix the audit rule, clearly distinguish that from a product defect, and rerun the complete relevant audit.

Do not offload obvious defects to the user's Windows test merely because the current environment cannot execute the whole Windows runtime.

If the build environment cannot reproduce real Windows/UAC/Codex behavior, say explicitly that a real Windows runtime test remains required.

Mandatory regression scans include at least:

```text
=\s*try\s*\{
```

and unsafe interpolated `$variable:` forms, except valid PowerShell scopes such as env/global/script/local/private/using.

Historical path regression — do not regress:

```text
NO: -RootPath "%ROOT%"
NO: -UsbRoot "%USBROOT%"
```

Do not pass root paths ending in backslash through CMD to PowerShell. Bootstrap/setup should derive roots from `$PSScriptRoot` where applicable. This regression caused repeated real Windows failures in the past.

Release audit also protects the unelevated Codex sandbox, updater/repository invariants, manifests, absence of `auth.json`, removed launchers, and other packaging rules.

## 10. Codex/auth baseline

Current pinned Codex CLI baseline: **0.151.0**. Version 0.152.0 previously caused device-auth problems in real testing, so do not casually bump it without a real reason and test.

Authentication baseline:

- normal `codex login` browser OAuth is primary;
- `codex login status` confirms login;
- do not copy host `%USERPROFILE%\.codex\auth.json`;
- do not inspect/log token contents;
- inherited process-only `CODEX_ACCESS_TOKEN` / `OPENAI_API_KEY` are cleared inside the process;
- `CODEX_HOME` remains portable.

`Setup-PortableCodex.ps1` is pinned to 0.151.0 / `rust-v0.151.0` and verifies official GitHub assets via digest.

Relevant config baseline:

```text
cli_auth_credentials_store = "file"
forced_login_method = "chatgpt"
```

Do not rewrite auth/bootstrap without a new real failure report.

## 11. Updater lifecycle

The updater checks for updates before the first task prompt.

A successful update exits with code 23; `system/ASK-AGENT.cmd` restarts `Start-Agent` in the same console. `SingleTask` child execution skips updater.

The updater verifies the GitHub Release `asset.digest` SHA-256 and updates only the intended project runtime while preserving portable tools/CodexHome/reports as designed.

A real update from v1.5.25 to v1.5.26 was successfully tested on Windows.

Current updater repository is `uah0/Dr.Swinux` and Dr.Swinux-named release assets are preferred while transitional legacy package names may still be recognized for compatibility.

## 12. Current Broker capability baseline

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

Known confirmed write capabilities:

16. InstallPackage
17. UninstallPackage
18. SetRegistryValue
19. RemoveRegistryValue

Package management is winget-only, uses exact package IDs, does not accept arbitrary installer paths/arguments, requires appropriate confirmation, and requires post-action verification.

Registry writes are constrained to the supported hives/existing keys and supported value types, with confirmation/reread verification and deny rules for sensitive/security/persistence/execution-hijack areas.

Ordinary removal of existing Run/RunOnce/StartupApproved entries may be allowed under policy; creation/modification of startup persistence remains denied.

## 13. Proven real-task behavior

Past real Windows work demonstrated generic reasoning rather than hardcoded workflows, including:

- Wi-Fi Broker inspection;
- crash diagnosis;
- investigation of a filling C: drive that found a large VDI clone and duplicate archives;
- reaching the real winget installation path;
- Explorer hidden-files configuration leading to a generic registry capability;
- an Edge startup problem leading to startup-removal and Scheduled Task capability work;
- firewall allowed-ports investigation where Codex corrected its own parser mistake.

Do not hardcode these cases as workflows. They are evidence that generic reasoning/capabilities can solve real tasks.

## 14. Windows test-machine history

A previously used physical test laptop was:

```text
HP EliteBook 840 G8
Windows 10 Pro 19045
~15.69 GB RAM
KIOXIA 256 GB NVMe
Intel AX201 Wi-Fi
```

This information is historical test context only. Never hardcode expected answers for that machine.

The next planned laboratory environment is a Windows 10 virtual machine. VM snapshots should be used to preserve/reproduce a problem state before Dr.Swinux attempts treatment.

## 15. LAB MODE — v1.5.32

v1.5.32 introduced the first autonomous development/lab loop.

Launcher:

`LAB-SWINUX.cmd`

Core files:

- `system/Lab-Loop.ps1`
- `system/Audit-LabCandidate.ps1`

Intended cycle:

```text
TASK
  -> ATTEMPT
  -> SOLVED -> DONE
  -> otherwise classify blocker
       -> reasoning retry where appropriate
       -> or real generic capability/tool/protocol/verification gap
            -> create isolated candidate copy of system/
            -> Codex makes the smallest generic patch
            -> guarded audit
            -> if audit fails: repair/reject candidate
            -> if audit passes: promote permitted changes locally
            -> restart/retry the SAME original task
```

Default maximum is three iterations so a bad self-improvement loop cannot run forever.

The Lab loop must distinguish at least these failure classes conceptually:

- existing capability not yet tried -> continue reasoning;
- existing tool available but not discovered/selected -> reasoning/tool-discovery issue;
- existing implementation broken -> tool bug;
- genuine missing observation capability -> capability gap;
- genuine missing action capability -> capability/policy gap;
- action executed but original symptom not rechecked -> verification gap;
- platform cannot provide required evidence/action -> concrete blocker;
- user decision/permission is genuinely required -> ask user.

Self-modification uses an isolated candidate and a guarded audit rather than blindly rewriting the running stable process.

Protected Lab/safety/update/auth/Broker files are not autonomously modifiable by the Lab candidate. A new privileged capability may be identified as a real gap, but the Lab must not autonomously weaken or expand the privilege boundary to solve it.

The v1.5.32 GitHub Actions release audit, build, ZIP verification, and publication succeeded. **The full Lab runtime still requires real Windows 10 VM testing; CI cannot validate the complete Codex/UAC/local-machine interaction.**

## 16. Next real development step

Do not start by inventing more diagnostics or plugins.

Install/run v1.5.32 on a Windows 10 VM, create a useful snapshot, initialize/authenticate the portable environment normally, then run `LAB-SWINUX.cmd` with a real ordinary-language computer task.

Observe the first actual failure of the end-to-end Lab loop. Preserve:

- original user task verbatim;
- VM snapshot/state;
- Dr.Swinux report/session directory;
- Lab case/result/classification;
- console error if any;
- whether the failure is reasoning, capability, permission/policy, tool implementation, verification, context/history, Lab orchestration, or another concrete class.

Patch only the real failing stage, audit, restore/reproduce the same initial state, and retry the exact same task.

## 17. Longer roadmap

Current direction, in order of evidence rather than rigid calendar milestones:

1. Prove the autonomous doctor loop across varied real Windows tasks.
2. Make observations/actions increasingly capability-driven where real tasks justify it.
3. Close action -> verification so command success is not confused with task success.
4. Build a structured local machine/case record from real sessions.
5. Use recorded capability gaps to drive self-extension rather than inventing a plugin catalogue.
6. Harden portable operation across unfamiliar Windows machines/removable media.
7. Extract only the platform-independent abstractions proven by Windows experience.
8. Implement/test a real Linux adapter.
9. Implement/test an Android-specific runtime under Android's actual capability/privilege model.

## 18. How to use this handoff in a new chat

At the start of a new ChatGPT conversation, provide this file or point the assistant to it and say approximately:

> Continue development of Dr.Swinux. Read `DR-SWINUX-HANDOFF.md` and the current repository before changing anything. Treat the repository as current source of truth for code and this handoff as source of truth for project decisions/history unless newer real test evidence supersedes it. After every code change, audit and iterate until clean.

Then provide the newest real test report/log/task if one exists.

The assistant should fetch current repository files before editing them because code may have changed since this handoff was last updated.

## 19. Handoff maintenance policy

Update this file when any of the following changes materially:

- product identity/goal;
- architectural definition of Dr.Swinux as the Codex-agent orchestrator;
- architecture or platform boundary;
- safety/privilege invariants;
- mandatory audit/process rules;
- Codex/auth/updater baseline;
- current stable release baseline;
- Lab-loop semantics/protected boundary;
- important real-machine findings that affect future decisions;
- next concrete development stage;
- a known technical debt item is resolved or a new important one is discovered.

Do not turn this into a duplicate of Git history. Git records what changed; this file records **what the next development conversation must know and why**.
