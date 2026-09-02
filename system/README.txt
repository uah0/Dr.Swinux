Doctor Swinux - portable AI engineer

PUBLIC PRODUCT NAME
  Doctor Swinux

TRANSITIONAL COMPATIBILITY
  Some proven Windows implementation filenames, log names, package root names,
  VERSION prefix and the current GitHub repository coordinate still use
  Dr.Swintus. They are compatibility identifiers so existing installations can
  update through the rename without breaking.

TOP-LEVEL LAYOUT
  ASK-AGENT.cmd.lnk
  tools\
  system\
  reports\

START
  Run normally:
    ASK-AGENT.cmd.lnk

  The shortcut points to system\ASK-AGENT.cmd. The CMD launcher invokes
  system\Start-DoctorSwinux.ps1, which provides Doctor Swinux branding while
  preserving the proven Windows Start-Agent runtime during the migration.

BRANDING
  Vector master:
    system\assets\branding\doctor-swinux.svg

  Compact vector icon master:
    system\assets\branding\doctor-swinux-icon.svg

  system\Create-Shortcut.ps1 generates a Windows .ico locally from the brand
  palette and assigns it to ASK-AGENT.cmd.lnk.

PORTABILITY
  No fixed drive letter is used. Runtime paths are derived from the project
  folder. Portable PowerShell, Codex and CodexHome stay under tools\.

AUTONOMOUS TASK MODEL
  ordinary-language task -> hypotheses -> observations -> decision -> action ->
  verification -> result

  The agent starts work on the current computer immediately, chooses its own
  useful checks, revises hypotheses from evidence, uses existing tools when they
  fit, and only needs new capabilities when a real task exposes a concrete gap.

SAFETY / PRIVILEGE MODEL
  Codex itself remains unelevated and runs with approval_policy="never",
  windows.sandbox="unelevated", and workspace-write for the report session.
  Administrator-only operations go through the separate typed allowlisted
  Broker. No arbitrary elevated shell is exposed.

  State-changing Broker operations remain confirmation-gated where required and
  must be followed by verification of the user's original goal.

UPDATES
  The update check runs before the first task prompt. Successful installation
  returns restart code 23 and system\ASK-AGENT.cmd restarts Doctor Swinux in the
  same console.

CROSS-PLATFORM ARCHITECTURE
  Shared contract:
    system\core\

  Platform adapters:
    system\platform\windows\   supported
    system\platform\linux\     planned
    system\platform\android\   planned

  Windows remains the reference implementation. Linux and Android become
  supported only after real runtimes are implemented and exercised on those
  platforms.
