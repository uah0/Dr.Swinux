# Dr.Swinux — portable AI doctor for computers

<p align="center">
  <img src="Dr.Swinux.png" alt="Dr.Swinux" width="420">
</p>

**Dr.Swinux** is a portable AI doctor for computers and an orchestrator for the Codex agent.

Codex is the agent and intelligence. **Dr.Swinux is the orchestration layer that turns the general Codex agent into the autonomous doctor of a particular computer.** It organizes the task lifecycle, gives Codex the context and capabilities of the current machine, controls access to privileged actions, records results and keeps the agent working until the original goal is verified or a concrete blocker is identified.

The idea is not to put Codex into a folder and add a collection of diagnostic scripts. Codex reasons, forms hypotheses and decides what evidence or action is needed. Dr.Swinux provides and orchestrates the environment in which that reasoning can safely observe, understand, treat and re-check a particular computer.

The user should be able to connect Dr.Swinux to a computer, launch it and describe a real problem or goal in ordinary language. The doctor then starts working on that machine: forms hypotheses, decides what evidence is needed, observes the system, rejects or refines hypotheses, performs allowed actions when necessary and verifies the original symptom or goal afterwards.

The target interaction is simple:

> Describe what is wrong or what you need. Dr.Swinux orchestrates the Codex agent as it investigates the computer, finds a solution, performs allowed actions and checks the result.

## Why not just run Codex?

Codex is the agent and reasoning engine. Dr.Swinux is its computer-doctor orchestrator.

A generic Codex agent can reason and execute commands in the environment available to it. Dr.Swinux adds a persistent, portable and platform-aware orchestration layer between that agent and the computer:

- a portable runtime that can be brought to another machine;
- task/session lifecycle and context for the particular computer;
- structured ways to observe the operating system instead of relying only on an unrestricted shell;
- a growing set of reusable local capabilities discovered through real tasks;
- a controlled path for privileged operations while Codex itself stays unelevated;
- an autonomous investigation cycle rather than a collection of predefined diagnostic workflows;
- verification against the user's original problem after state-changing actions;
- reports and, ultimately, longitudinal knowledge of the particular computer: what was observed, what changed, why it changed and whether it helped;
- platform adapters that let the same doctor work with different operating systems without pretending that Windows, Linux and Android expose the same mechanisms.

In short:

**Codex is the agent and intelligence. Dr.Swinux is the orchestrator that makes that agent operate as the doctor of the current computer.**

## The doctor's working cycle

```text
user's symptom or goal
        ↓
Dr.Swinux starts/maintains the task context
        ↓
Codex understands the task and forms hypotheses
        ↓
Codex chooses the smallest useful observation
        ↓
Dr.Swinux exposes the appropriate local capability
        ↓
gather local evidence
        ↓
Codex confirms / rejects / refines hypotheses
        ↓
choose an action when justified
        ↓
Dr.Swinux routes execution through the appropriate capability / Broker
        ↓
verify the original symptom or goal
        ↓
continue if the problem is not solved
```

The list of hypotheses is not supposed to be hardcoded. Codex reasons about the actual task and actual machine; Dr.Swinux orchestrates the context, capabilities, execution boundary and lifecycle around that reasoning.

Diagnostics are therefore only one possible activity. Dr.Swinux may orchestrate Codex while it investigates a failure, configures something, installs or removes supported software, inspects applications and system components, corrects an allowed setting, collects evidence, or performs another computer task for which the platform has a safe capability.

## Tools follow real problems

Dr.Swinux is not developed by inventing hundreds of narrow workflows in advance.

A real task drives development. If Codex decides that a particular observation or action is necessary and Dr.Swinux cannot provide an appropriate platform capability, that is a real **capability gap**. A reusable capability can then be added, audited and tested on the task that exposed the gap.

The intended direction is:

`real task -> Codex reasoning -> missing capability discovered -> generic Dr.Swinux capability added -> original task re-tested`

This keeps the doctor general-purpose. Tools provide senses and hands; they do not decide the diagnosis. Dr.Swinux orchestrates their availability and execution; Codex decides how they contribute to solving the task.

## Safety and execution authority

Reasoning authority and execution authority are deliberately separated.

Codex itself stays unelevated. It can reason freely and use the capabilities made available by Dr.Swinux, but privileged Windows operations go through a typed allowlisted Broker. Dr.Swinux owns this execution boundary: state-changing actions retain the appropriate confirmation and are followed by verification.

Dr.Swinux does not give Codex an unrestricted elevated shell.

This architecture is intended to allow useful autonomy without making administrator access the default execution environment of the AI.

## Memory of the computer

A mature Dr.Swinux should orchestrate more than the current command output. It should maintain a local history that can be supplied to Codex when relevant, for example:

```text
computer
├── hardware
├── operating system
├── drivers
├── installed software
├── storage
├── network
├── services and system components
└── history
    ├── previous symptoms
    ├── observations
    ├── actions performed
    ├── reasons for those actions
    └── verification results
```

This would let the agent compare a new problem with previous incidents and changes instead of treating every session as a completely unknown machine.

The history must remain evidence, not dogma: previous conclusions can guide hypotheses but current observations must still be checked.

## Portable and cross-platform

Portability means more than storing Codex on a USB drive. Dr.Swinux should bring the orchestration environment and tools to an unfamiliar computer, determine what platform capabilities are available and give the Codex agent the appropriate context and instruments for that machine.

The common orchestration and doctor loop belong to the core. Operating-system-specific mechanisms belong to platform adapters.

```text
              Dr.Swinux orchestrator/core
                       │
                   Codex agent
                       │
           ┌───────────┼───────────┐
           ↓           ↓           ↓
        Windows       Linux      Android
           │           │           │
        Broker        sudo      Android APIs
        winget     package mgr   optional bridge
        WMI/CIM      /proc
        Event Log    journal
```

Windows is the current supported reference implementation. Linux and Android remain planned until real runtimes are implemented and tested.

## Windows today

Launch the root shortcut `ASK-AGENT.cmd.lnk`. Dr.Swinux prepares and orchestrates its portable PowerShell/Codex environment inside the project folder. The project can run from its own folder on a computer, external drive or USB stick.

The user does not need to translate the problem into diagnostic commands or select a predefined workflow. The natural-language task is the starting point.

Current architecture:

```text
system/
  core/                 common orchestration, doctor behavior and platform contract
  platform/
    windows/            current supported platform
    linux/              planned runtime
    android/             planned runtime
  assets/branding/      Dr.Swinux branding
```

## Development roadmap

Development is driven by real Windows tasks first. Architecture changes and new tools should have a concrete reason demonstrated by an actual task.

### Phase 1 — prove the Windows doctor loop

Use Dr.Swinux on varied real computers and real user problems. For every task, determine whether the orchestrated Codex agent can autonomously move through hypothesis, observation, decision, action and verification. Fix generic orchestration/reasoning/execution problems in the core and Windows-specific gaps in the Windows platform layer.

Success criterion: the user normally describes the goal once and the Dr.Swinux-orchestrated agent can continue working without being manually walked through diagnostic commands.

### Phase 2 — make observations capability-driven

Gradually expose reusable, structured platform capabilities for evidence Codex actually needs. Avoid task-specific workflows. Each capability should describe what it can observe or do, its requirements and its risk level so the agent can choose it during reasoning.

Success criterion: adding a capability expands what the doctor can solve rather than adding one hardcoded scenario.

### Phase 3 — close the action/verification loop

Make state-changing operations first-class typed capabilities with explicit preconditions, confirmation policy, execution result and post-action verification. Dr.Swinux should keep the Codex agent tied to the user's original symptom after an action rather than allowing successful command execution to be confused with task success.

Success criterion: technical command success and actual task success are treated as different things.

### Phase 4 — build the machine record

Introduce a local machine identity and structured history for observations, incidents, actions and verification results. Keep raw evidence and conclusions distinguishable. Let new sessions supply relevant prior incidents to Codex without blindly reusing old diagnoses.

Success criterion: the orchestrated doctor can answer questions such as “what changed since this last worked?” using evidence collected on that computer.

### Phase 5 — capability discovery and self-extension workflow

When a real task reaches a missing capability, record the gap precisely: what Codex tried to learn or do, why existing Dr.Swinux capabilities were insufficient and what evidence would close the gap. Use those records to drive development of generic tools and platform adapters.

Success criterion: the project grows from observed limitations instead of an invented plugin catalogue.

### Phase 6 — harden portability

Exercise clean launches on unfamiliar Windows machines, removable media and different Windows configurations. Keep bootstrap, Codex authentication, updates, reports and local machine data separated correctly so moving the orchestrator does not accidentally mix machine-specific state.

Success criterion: connecting Dr.Swinux to another supported Windows computer is a normal operating mode rather than a special installation procedure.

### Phase 7 — extract the proven cross-platform core

Only after the Windows doctor loop has enough real-task evidence, identify which orchestration behavior is genuinely platform-independent. Keep task lifecycle, Codex lifecycle, capability contracts, evidence/history model and verification semantics in the core; keep OS mechanisms in adapters.

Success criterion: the common core contains proven abstractions rather than abstractions invented before a second platform exists.

### Phase 8 — Linux runtime

Implement the first real Linux adapter against the proven capability contract, starting with a narrow supported Linux baseline and real Linux tasks. Use native Linux evidence and package/service mechanisms rather than translating Windows commands mechanically.

### Phase 9 — Android runtime

Build an Android-specific runtime around the same orchestrator/doctor model where Android permits it. Android capabilities and privilege models must be treated as Android concepts; optional mechanisms such as Shizuku or root can extend capabilities but should not define the basic architecture.

## Development rule

The central rule of the project is:

> **Do not invent work for Dr.Swinux. Give the Codex agent real work. When real work exposes a missing sense, hand or platform capability, improve the Dr.Swinux orchestration layer and test the original problem again.**

Every code change is followed by audit. A change is not considered complete merely because it was written; it must survive the project's automated checks and, where the behavior depends on Windows, ultimately be exercised on a real Windows machine.

## Updates and repository

The repository is **`uah0/Dr.Swinux`**. The updater checks this repository before the first task prompt and verifies the GitHub Release asset digest before installation. Release packages are named `Dr.Swinux-v<version>-final.zip`.

**Windows: supported | Linux: planned | Android: planned**
