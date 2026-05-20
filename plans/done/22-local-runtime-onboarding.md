# Local Runtime Onboarding Plan

Completed. This plan is historical context for Donkey's first-run local runtime
setup flow.

## Supported Outcome

Donkey now supports a normal post-install runtime setup boundary:

- first-launch setup window with one primary setup button
- app-managed runtime registry under Application Support
- bundled runner packages embedded in `Donkey.app`
- offline wheelhouse packaging support for Parakeet and YOLO dependencies
- Swift UI-understanding sidecar backed by Apple Vision text recognition
- manifest validation for runtime id, platform, architecture, executable path,
  required signature metadata, configured release-key signatures, and SHA-256
  file hashes
- package install into managed Application Support directories
- setup-time model preparation before health checks
- sidecar `healthCheck` protocol
- retryable setup that keeps completed installs and resumes failed or missing
  runtimes
- settings access to reopen setup
- repair/remove lifecycle helpers
- user-data-free support status export
- app-registry sidecar resolution when shell environment variables are absent
- developer debug commands for setup instructions, status, support status,
  repair, remove, and manual runtime registration

The supported behavior is documented in:

- `docs/architecture.md`
- `docs/guides/install-donkey.md`
- `docs/guides/agent-harness.md`

## Follow-Up Work

Remaining milestone proof is tracked by `plans/master-plan.md`, not this
completed plan.
