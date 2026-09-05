Dr.Swinux managed diagnostic backends

This directory is reserved for portable diagnostic backends managed by Dr.Swinux adapters.
Codex must not execute third-party binaries from this directory directly. It uses the typed
system/Diagnostic-Tool.ps1 facade (copied into each task workspace) so backends can be added,
replaced, version-pinned, verified, or removed without changing the agent-facing API.

No third-party diagnostic binaries are bundled in v1.5.65. Future osquery/Sysinternals or other
backends must be integrated through fixed typed adapters with source/version/hash/licensing review.
