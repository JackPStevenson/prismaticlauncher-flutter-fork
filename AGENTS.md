# Agent Guidance

## Project status

Prismatic Launcher (this fork) is a Flutter/Dart desktop experiment ported from the C++20/Qt 6 upstream project. It has application sources, tests, and build/CI infrastructure; it is not merged back upstream. `documents/infrastructure_plan.md` records the approved infrastructure decisions. Product changes follow the user's requested feature scope; infrastructure-only tasks stay within the infrastructure boundaries below.

## Repository map

- `pubspec.yaml`, `pubspec.lock` — Dart/Flutter dependencies.
- `analysis_options.yaml` — analyzer lints and the 100-column formatter width.
- `scripts/` — infrastructure checks and Linux CI entrypoint.
- `tests/infrastructure/` — Python checks for agent customizations.
- `test/` — Flutter tests (`flutter test`) for services and UI.
- `Dockerfile.ci`, `.dockerignore` — Linux validation infrastructure only.
- `.github/workflows/pr-checks.yml`, `.github/workflows/release.yml` — CI and guarded release workflows.
- `README.md`, `documents/infrastructure_plan.md` — developer documentation and approved infrastructure plan.
- `.agents/skills/` — local skill instructions.
- `.agents/*.toml` — existing agent role definitions.
- `.github/agents/*.agent.md` — generated VS Code agent roles; regenerate with `python3 scripts/sync-vscode-agents.py` (Python 3.11+), verify with `--check`. Role sources are `.agents/*.toml` and `.codex/agents/*.toml`. The command also validates canonical skills in `.agents/skills/`; do not create duplicate skill entries under `.github/skills/`.
- `.codex/agents/*.toml`, `.codex/config.toml` — native Codex feature workers and project delegation settings.
- `documents/templates/feature-request.md` — reusable feature request template.
- `lib/ui/`, `lib/smapi/`, `lib/mods/`, `lib/farmpack/`, `lib/nexus_fetch_list/` — Flutter application and services; each file names the C++ source it was ported from.
- `linux/`, `windows/`, `macos/` — generated Flutter desktop runners.

## Required reading and skill selection

Read `documents/infrastructure_plan.md`, this file, and the relevant `.agents/skills/*/SKILL.md` before changing the repository. Use `infra-planner` to revise infrastructure decisions; `infra-builder` for plan-approved tooling; `incremental-implementation` and `test-driven-development` for product changes; `browser-testing-with-devtools` or `test-in-browser` only for browser surfaces; `security-and-hardening` for untrusted inputs or external integrations; `documentation-and-adrs` for durable design records; `code-review-and-quality` before merge; `ci-cd-and-automation` for workflow changes; and `git-workflow-and-versioning` for every change.

Use `refine-task` when asked to evaluate or rewrite a draft task prompt. It prepares the prompt without implementing its contents; it is not a mandatory step for ordinary coding requests.

Use `feature-workflow` for end-to-end application feature requests covering refinement, planning, implementation, tests, and independent review. Its coordinator delegates focused assignments to `feature-planner`, `feature-implementer`, `feature-tester`, and `feature-reviewer` when available. Keep plan-only and prompt-only requests within their stated scope. Follow [the workflow skill](.agents/skills/feature-workflow/SKILL.md) and use [the request template](documents/templates/feature-request.md).

Prefer visible Sessions/chat delegation when the client exposes `create_session`; follow the workflow skill for tool selection and coordination. Title each assignment `<role> — <assignment>`, share its returned open link, and have each worker identify its role/name, selected skills with links to `SKILL.md`, and assigned files with read-only or writer scope in its first commentary. Do not imply that the UI automatically shows active skills. Workers do not recursively delegate. Do not stage, commit, push, publish, or deploy unless the user separately requests it.

## Development environment

- This checkout lives in the Ubuntu WSL distribution. Run repository commands with Bash inside WSL, not PowerShell against the `\\wsl.localhost` UNC path.
- Open the checkout through VS Code Remote - WSL so agent sessions inherit `/home/jpste/Git/prismaticlauncher` and Linux tools. A Windows-side window opened directly on the UNC path selects a Windows agent host and can fall back to PowerShell.
- From WSL, use the `code` CLI to open files or the checkout in the Windows VS Code client. Workspace settings auto-approve the `code` and `code.exe` bridge commands; this does not grant blanket approval to other terminal commands.

## Boundaries

- Do not add product UI, game discovery, mod-management behavior, domain schema, or release packaging while doing infrastructure-only work.
- Do not change the selected Flutter, SQLite, Docker, or GitHub Release decisions without revising `documents/infrastructure_plan.md` through `infra-planner`.
- Do not commit secrets, signing certificates, generated build output, coverage reports, `.dart_tool/`, or local game/mod data.
- Docker validates Linux only; it does not replace native Windows/macOS packaging, signing, or macOS notarization.

## Code readability and documentation

Apply these conventions to new or substantially changed code, including tests and helpers. All agents that implement, refactor, or verify code must use this standard. Keep unrelated code outside the task's scope.

### Readable implementations

- Prefer clear, explicit code over compact expressions. Use descriptive names that express purpose, units, and boolean meaning; follow the surrounding naming conventions.
- Give each function one clear responsibility. Use guard clauses to keep the main flow easy to follow, and extract named helpers when they clarify a meaningful operation. Avoid nested ternaries, long compound conditions, and abstractions that add indirection without clarity.
- Use named intermediate values for complex expressions and constants for meaningful repeated values. Make ownership, lifetime, side effects, and error handling clear, especially around widget state, isolates, processes, and filesystem operations.
- Format Dart with `dart format` (100 columns, set in `analysis_options.yaml`). Use the existing language conventions for scripts and tooling.

### Function summaries

- Add a concise, accurate summary to every new or substantially changed named function, method, constructor, and test function or helper. Generated code and declarations explicitly marked `= default` or `= delete` are exempt.
- For Dart, use `/// @brief` followed by a sentence describing the function's purpose and observable behavior, immediately above the declaration. (This keeps the upstream C++ convention so ported files read the same as their originals.)
- Add `/// @param`, `/// @return`, and `/// @throws` only when they explain a meaningful contract: valid inputs, units, ownership transfer, output values, failure behavior, or exceptions. Explain both outcomes of boolean results. Do not add return documentation to constructors or void functions, and do not merely repeat types or parameter names.
- Document relevant side effects, preconditions, thread requirements, or asynchronous completion in the same block when callers need them. Describe actual behavior verified in the implementation; do not invent guarantees.
- For Python, use a short docstring; for shell and CMake functions, use a short comment above the definition. Test summaries should state the scenario and expected outcome.

Example of a constructor summary:

```dart
/// @brief Takes the launcher used to start SMAPI after a successful inspection.
SmapiManager(this._launcher);
```

### Comments within functions

- Use `//` comments to explain intent, invariants, platform constraints, workarounds, or ordering requirements that are not clear from the code. Briefly introduce a complex processing stage when it helps the reader follow the function.
- Keep comments factual, concise, and in complete sentences. Explain why a decision is necessary; avoid narrating obvious statements or adding a comment to every line. Prefer a clearer name or a small helper when a comment would only explain a dense expression.
- Update or remove stale comments as behavior changes. Preserve useful rationale, and do not leave commented-out implementations.

### Before handoff

Read the changed code as a maintainer: verify descriptive names, straightforward control flow, function summaries in the correct place, accurate contracts, and useful comments. Run the relevant formatter and behavior checks, and report what was verified.

## Verification

Run these commands from the repository root when their prerequisites are installed:

```bash
./scripts/verify-infrastructure.sh
./scripts/format-check.sh
./scripts/static-analysis.sh
flutter test
docker build --pull=false -f Dockerfile.ci -t prismaticlauncher-ci:local .
docker run --rm prismaticlauncher-ci:local
```

CI mirrors these checks in `.github/workflows/pr-checks.yml`. No service lifecycle is required: the Docker image is disposable, starts no daemon, exposes no ports, and should be removed with `docker image rm prismaticlauncher-ci:local` when no longer needed.

## Change checklist

1. Read the plan and applicable local instructions.
2. Keep the change within its approved boundary and update documentation when commands, paths, prerequisites, or CI behavior change.
3. Run the relevant local checks and report anything not verified.
4. Inspect `git diff --check` and the changed-file list before handoff.
