# Platform adapters

This directory is the operating-system boundary of **Doctor Swinux**.

- `windows/` is the current supported implementation and points to the proven Windows runtime.
- `linux/` is reserved for the next real implementation.
- `android/` is reserved for the later Android implementation.

The shared behavioral contract lives in `system/core/ARCHITECTURE.md`.

A platform manifest describes capabilities and entrypoints; it does not grant capabilities by itself. A platform becomes `supported` only after its real launcher, runtime, broker and task loop have been exercised on that platform.

During the rename transition some Windows implementation files still carry `Dr.Swintus` names for backward-compatible updating. They are compatibility identifiers, not the public product name.
