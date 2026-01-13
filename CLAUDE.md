# UVCCamera-Experimental Project Instructions

## Project Overview

**Purpose:** Modernize the UVCCamera Android library for ScopeCam scientific imaging application.

**Architecture:** Two-repo split:
- **This repo (uvccamera-experimental):** libuvc source, ndk-build, JNI bridge
- **scopecam-engine:** Kotlin + C++20, consumes prebuilt .so files

**Authoritative Documents:**
- `adr-proposal.md` — ARCH-DECISIONS-001-R2 (binding decisions)
- `imp-plan.md` — Concrete implementation plan
- `docs/status/IMPLEMENTATION-STATUS.md` — Current progress tracker

---

## Critical Rules

### Before Any Code Change

1. **Check status:** Read `docs/status/IMPLEMENTATION-STATUS.md`
2. **Verify phase:** Ensure you're working on the current active phase
3. **Reference ADR:** All changes must align with a specific DECISION-XXX
4. **Check blockers:** Phase 0-Pre must complete before Phase 0

### Code Standards

- **C++ Standard:** C++17 (enforced via `APP_CPPFLAGS += -std=c++17`)
- **ABI Boundary:** C ABI only between libuvc.so and scopecam-engine (no STL types)
- **Error Handling:** Use `uvc::expected` pattern (after Phase 0-Pre)
- **Telemetry:** Every new feature must expose metrics

### Testing Requirements

- **Unit tests:** Required for all new functions
- **Integration:** Verify with `tools/sync_to_engine.sh` after changes
- **Build verification:** Both ABIs (arm64-v8a, armeabi-v7a) must build
- **Runtime:** Log `uvc_build_id()` to verify correct binary loaded

---

## Key File Locations

### This Repo (uvccamera-experimental)

| Purpose | Path |
|---------|------|
| libuvc source | `lib/src/main/jni/libuvc/src/` |
| libuvc headers | `lib/src/main/jni/libuvc/include/libuvc/` |
| JNI bridge | `lib/src/main/jni/UVCCamera/` |
| Build config | `lib/src/main/jni/Android.mk`, `Application.mk` |
| Sync script | `tools/sync_to_engine.sh` |
| Status tracking | `docs/status/` |

### Scopecam-Engine (for reference)

| Purpose | Path |
|---------|------|
| Prebuilt libs | `nativecode/src/main/libs/{ABI}/` |
| Engine native | `nativecode/src/main/cpp/` |
| Kotlin API | `camera-platform/src/main/kotlin/` |
| Telemetry | `nativecode/src/main/cpp/core/StreamTelemetry.h` |

---

## Implementation Workflow

### Starting a Task

```bash
# 1. Check current status
cat docs/status/IMPLEMENTATION-STATUS.md

# 2. Update status to in-progress
# Edit the task line: [ ] → [~]

# 3. Reference the relevant decision
# grep "DECISION-XXX" adr-proposal.md
```

### Completing a Task

```bash
# 1. Build and verify
./tools/sync_to_engine.sh

# 2. Update status
# Edit the task line: [~] → [x]

# 3. Add completion notes to status file

# 4. Commit with decision reference
git commit -m "feat(phase-X): implement DECISION-XXX - description"
```

### Handling Unexpected Changes

If implementation reveals issues not covered by ADR:

1. Document in `docs/status/DEVIATIONS.md`
2. Add `[!]` marker to affected task in status
3. Propose ADR amendment if architectural
4. Continue with best judgment for tactical issues

---

## Phase Dependencies

```
Phase 0-Pre (BLOCKER - must complete first)
    ↓
Phase 0 (Week 1)
    ↓
Phase 1 (Weeks 2-3)
    ↓
Phase 2 (Weeks 4-5)
    ↓
Phase 3 (Weeks 6-9)
    ↓
Phase 4 (Weeks 10-12)
```

**Never start a phase before completing the previous phase's blocking items.**

---

## Development Environment

This project uses **mise** for tool version management and **direnv** for environment loading.

### Setup

```bash
# Install prerequisites (if not already present)
brew install mise direnv

# Allow direnv in this directory
direnv allow

# Install project tools
mise install
```

### Available mise Tasks

| Command | Description |
|---------|-------------|
| `mise run build` | Build release AAR |
| `mise run build-native` | Build native libraries with ndk-build |
| `mise run clean` | Clean all build artifacts |
| `mise run sync` | Sync prebuilt .so files to scopecam-engine |
| `mise run lint` | Run ktlint and detekt |
| `mise run test` | Run unit tests |
| `mise run test-native` | Run native C++ tests (GTest) |
| `mise run format` | Format C++ code with clang-format |
| `mise run hooks-install` | Install git hooks via lefthook |

### Pinned Tool Versions

- **Java:** temurin-17 (required for Android Gradle Plugin)
- **lefthook:** latest (git hooks)
- **shellcheck:** latest (shell script linting)
- **yamllint:** latest (CI config linting)

### Git Hooks (Lefthook)

Pre-commit hooks run automatically:
- **clang-format** on staged C++ files
- **shellcheck** on staged shell scripts

Pre-push hooks:
- **Quick build** to catch compile errors before push

---

## Common Operations

### Build libuvc (via mise)

```bash
mise run build-native
```

### Build libuvc (manual)

```bash
cd lib/src/main
$ANDROID_NDK_HOME/ndk-build -j$(sysctl -n hw.ncpu) \
    NDK_PROJECT_PATH="$(pwd)" \
    NDK_APPLICATION_MK="$(pwd)/jni/Application.mk"
```

### Sync to scopecam-engine

```bash
mise run sync
# or
./tools/sync_to_engine.sh
```

### Verify Build ID

After running app, check logcat for:
```
libuvc build: uvccamera-experimental:<git-sha>@<timestamp>
```

### Search for Decision Context

```bash
# Find all references to a decision
grep -rn "DECISION-006" . --include="*.md"

# Find implementation locations
grep -rn "pts_raw\|PTS" lib/src/main/jni/ --include="*.c" --include="*.h"
```

---

## Commit Message Format

```
<type>(<scope>): <description>

Implements DECISION-XXX
Phase: <phase-number>

<body>
```

**Types:** feat, fix, refactor, docs, test, chore
**Scopes:** phase-0-pre, phase-0, phase-1, phase-2, phase-3, phase-4, libuvc, jni, build

**Examples:**
```
feat(phase-0-pre): add build ID export to JNI bridge

Implements DECISION-017
Phase: 0-Pre

- Add uvc_build_id.c with git SHA and timestamp
- Inject defines via Android.mk
- Log at camera open in scopecam-engine
```

---

## Quality Gates

### Phase Completion Criteria

Each phase must pass before proceeding:

1. **All tasks marked [x]** in status file
2. **Build succeeds** for both ABIs
3. **Sync completes** without errors
4. **Runtime verification** (build ID logged)
5. **No [!] deviations** unresolved

### Pre-Merge Checklist

- [ ] Status file updated
- [ ] ADR reference in commit message
- [ ] Both ABIs build
- [ ] Sync script passes
- [ ] No compiler warnings introduced
- [ ] Telemetry added for new features

---

## Emergency Procedures

### Build Failure After Sync

```bash
# Revert to known-good prebuilts
cd ~/Development/personal/scopecam-engine
git checkout -- nativecode/src/main/libs/

# Check what changed
git diff HEAD~1 -- lib/src/main/jni/
```

### ABI Mismatch Detected

```bash
# Verify NDK version matches
echo $ANDROID_NDK_HOME
# Should be: .../ndk/27.0.12077973

# Check STL setting
grep APP_STL lib/src/main/jni/Application.mk
# Should be: c++_shared
```

### Status File Conflicts

```bash
# Status file is source of truth
# If conflicts, prefer the more conservative (incomplete) state
# Re-verify completed tasks before marking done
```

---

## Agent Instructions

When working autonomously on this project:

1. **Always start** by reading `docs/status/IMPLEMENTATION-STATUS.md`
2. **Work on one task at a time** from the current phase
3. **Update status immediately** when starting/completing tasks
4. **Reference decisions** in all changes
5. **Build and verify** after each significant change
6. **Document deviations** in `docs/status/DEVIATIONS.md`
7. **Never skip phases** or work ahead without explicit approval

---

*This file is the project-level configuration for Claude Code CLI.*
