# uvccamera-experimental Project Instructions

## Project Role

> **This is a SANDBOX repository, not a production supplier.**

**Purpose:** Testing ground for UVC library improvements before they are promoted to scopecam-engine via patches.

**Outputs:**
- Validated patches (source-to-source)
- Documentation of changes
- Test results and validation reports

**NOT Outputs:**
- Production binaries
- .so files for other projects
- Anything that bypasses scopecam-engine's build

---

## Critical Understanding

### What This Project Does

| Activity | Description |
|----------|-------------|
| Test libuvc changes | PTS/SCR timestamps, GET_INFO, protocol compliance |
| Validate in isolation | Prove changes work before promotion |
| Generate patches | `git format-patch` or `git diff` |
| Document changes | What, why, how to use, test results |

### What This Project Does NOT Do

| Anti-Pattern | Why It's Wrong |
|--------------|----------------|
| Sync .so files to scopecam-engine | Binary dependency hell |
| Produce production binaries | scopecam-engine builds from source |
| Modify scopecam-engine directly | Changes must go through patch review |
| Skip isolated testing | Untested changes break production |

---

## Authoritative Documents

| Document | Purpose |
|----------|---------|
| `adr-proposal.md` | ARCH-DECISIONS-001-R2 (binding decisions) |
| `imp-plan.md` | Concrete implementation plan |
| `docs/status/IMPLEMENTATION-STATUS.md` | Current progress tracker |
| `docs/PROMOTION_WORKFLOW.md` | Patch promotion process |

---

## Development Workflow

### Starting a Task

```bash
# 1. Check current status
cat docs/status/IMPLEMENTATION-STATUS.md

# 2. Update status to in-progress
# Edit the task line: [ ] → [~]

# 3. Reference the relevant decision
grep "DECISION-XXX" adr-proposal.md
```

### Testing Your Changes

```bash
# Build the test harness
./gradlew :lib:assembleDebug

# Install and test on device
./gradlew :app:installDebug
adb logcat | grep -E "(UVC|PTS|SCR)"
```

### Creating a Patch for Promotion

When changes are validated and ready for scopecam-engine:

```bash
# Option A: Single commit patch (preferred)
cd lib/src/main/jni/libuvc
git add -A
git commit -m "feat: Add PTS/SCR timestamp extraction"
git format-patch -1 HEAD --stdout > ~/patches/libuvc-pts-scr.patch

# Option B: Diff against baseline
git diff origin/main > ~/patches/libuvc-pts-scr.patch
```

### Documenting the Patch

Create a companion markdown file:

```markdown
# PTS/SCR Timestamp Extraction

## Summary
What the patch does...

## Files Changed
- src/stream.c: Parse PTS/SCR in _uvc_process_payload()
- include/libuvc/libuvc.h: Add fields to uvc_frame_t

## Testing
- Device: Realtek 0BDA:5880
- Procedure: Streamed 1080p30 for 10 minutes
- Results: PTS present 98.7%, monotonic

## ADR Reference
Implements DECISION-006
```

See `docs/PROMOTION_WORKFLOW.md` for the complete process.

---

## Code Standards

### C++ Standard
- **C++17** (enforced via `APP_CPPFLAGS += -std=c++17`)

### Error Handling
- Use `uvc::expected` pattern for new code

### Testing Requirements
- Unit tests required for all new functions
- Build verification for both ABIs (arm64-v8a, armeabi-v7a)
- Runtime testing with actual hardware

---

## Key File Locations

| Purpose | Path |
|---------|------|
| libuvc source | `lib/src/main/jni/libuvc/src/` |
| libuvc headers | `lib/src/main/jni/libuvc/include/libuvc/` |
| JNI bridge (test harness) | `lib/src/main/jni/UVCCamera/` |
| Build config | `lib/src/main/jni/Android.mk`, `Application.mk` |
| Status tracking | `docs/status/` |
| Promotion workflow | `docs/PROMOTION_WORKFLOW.md` |

---

## Development Environment

### Setup

```bash
# Install prerequisites
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
| `mise run lint` | Run ktlint and detekt |
| `mise run test` | Run unit tests |
| `mise run test-native` | Run native C++ tests (GTest) |
| `mise run format` | Format C++ code with clang-format |
| `mise run hooks-install` | Install git hooks via lefthook |

**DEPRECATED:** `mise run sync` - No longer used. See patch promotion workflow.

### Git Hooks (Lefthook)

Pre-commit hooks run automatically:
- **clang-format** on staged C++ files
- **shellcheck** on staged shell scripts

Pre-push hooks:
- **Quick build** to catch compile errors before push

---

## Phase Dependencies

```
Phase 0-Pre (Infrastructure) ✅ COMPLETE
    ↓
Phase 0 (PTS/SCR Timestamps) ✅ COMPLETE & SYNCED
    ↓
Phase 1 (GET_INFO Compliance) ← CURRENT FOCUS (Task 1.1 complete)
    ↓
Phase 2 (Clock Synchronizer)
    ↓
Phase 3-4 (Advanced Features)
```

### Deliverables per Phase

For each completed phase, produce:
1. **Tested code** that passes all verification
2. **Patch file(s)** for promotion
3. **Documentation** of changes
4. **Test evidence** (logs, results)

---

## Commit Message Format

```
<type>(<scope>): <description>

Implements DECISION-XXX
Phase: <phase-number>

<body>
```

**Types:** feat, fix, refactor, docs, test, chore
**Scopes:** phase-0, phase-1, phase-2, libuvc, jni, build

**Example:**
```
feat(phase-0): add PTS/SCR timestamp extraction

Implements DECISION-006
Phase: 0

- Parse PTS/SCR in _uvc_process_payload()
- Add fields to uvc_frame_t struct
- Tested with Realtek 0BDA:5880
```

---

## Agent Instructions

When working autonomously on this project:

### Core Principles

1. **This is a sandbox** - Test changes in isolation
2. **No production binaries** - Only produce patches and documentation
3. **scopecam-engine builds its own code** - Never bypass their build

### Workflow

1. **Read status** first: `docs/status/IMPLEMENTATION-STATUS.md`
2. **Work on current phase** only
3. **Test thoroughly** before considering promotion
4. **Create patches** when ready (not binaries)
5. **Document everything** - What, why, test results

### Quality Gates

Before considering a change ready for promotion:
- [ ] Build succeeds for both ABIs
- [ ] Tests pass with actual hardware
- [ ] No regressions in existing functionality
- [ ] Documentation complete
- [ ] Patch applies cleanly

### What NOT to Do

- ❌ Run the deprecated sync script
- ❌ Produce binaries for scopecam-engine
- ❌ Modify scopecam-engine's code directly
- ❌ Skip isolated testing
- ❌ Push untested patches

---

## Relationship with scopecam-engine

### Architecture

```
uvccamera-experimental              scopecam-engine
├── libuvc (test changes here)     ├── third_party/ (vendors source)
├── libusb                         ├── patches/ (applies our patches)
├── libjpeg-turbo                  └── libscopecam-engine.so (builds)
└── Test harness app
```

### Communication Channel

**Patches flow from here → scopecam-engine**

1. We create and test patches
2. We document changes
3. scopecam-engine reviews and applies
4. They build from source

### Key Understanding

- scopecam-engine **vendors source** in `third_party/`
- scopecam-engine **builds everything** with CMake
- scopecam-engine **owns its build ID** and provenance
- We **prove changes work** before they adopt them

### Binding Directives (2026-01-14)

**CRITICAL:** Binding directives have been issued to scopecam-engine:

| Document | Purpose |
|----------|---------|
| `patches/SCOPECAM_ENGINE_WARM_GATE_DIRECTIVE.md` | Surface lease + WARM gate (R2) |
| `patches/SCOPECAM_ENGINE_VIDEO_RECORDING_DIRECTIVE.md` | Video recording + capture commit (R2) |
| `docs/ScopeCam-Integration-Guide.md` §0 | Integration patterns |

**Key Issues Identified:**

1. **WARM Gate (FD Truth):** Java-layer FD checks ALWAYS fail with `openSimple()`. Use `getPreviewState()` / `querySessionDiagnostic()`.

2. **Surface Lease Race:** Two competing paths attach/detach surfaces. **Single Owner** pattern required via `SurfaceLeaseController`.

3. **Video Recording Race:** Two competing `dequeueOutputBuffer()` paths. **Single Owner** pattern required via `RecordingPipelineController`.

4. **Capture Commit Bug:** Videos saved to MediaStore but NOT inserted into app DB → invisible in app gallery. **Capture Commit** pattern required.

**Architectural Boundaries:**

```
┌─────────────────────────────────────────────────────────────────────┐
│  NATIVE (uvccamera) OWNS:             KOTLIN (scopecam) OWNS:        │
│  ├── USB session (FD after dup)       ├── Android lifecycle          │
│  ├── Preview pipeline                 ├── UI surfaces (single owner) │
│  ├── Frame production                 ├── Recording (single owner)   │
│  ├── Ring buffer                      ├── MediaStore publishing      │
│  ├── Timestamps (PTS/SCR)             ├── DB persistence (Room)      │
│  └── WARM/HOT state machine           ├── Gallery view model         │
│                                       └── Reconciliation             │
│                                                                      │
│  INVARIANT: ONE component controls each resource. Others REQUEST.    │
│  BOUNDARY: Native delivers frames. Kotlin owns capture persistence.  │
└─────────────────────────────────────────────────────────────────────┘
```

**Source of Truth:** Room DB is gallery source-of-truth. MediaStore is storage backend.

**Capture Commit Pattern:**
```
Capture Commit = MediaStore write + DB insert + Metadata attached
```
Both photo AND video MUST use the same `commitCapture()` function.

**ScopeCam Required Actions:**
1. **`SurfaceLeaseController`** - Single owner of surface attach/detach
2. **`RecordingPipelineController`** - Single owner of codec/muxer
3. **`commitCapture()`** - Shared by photo AND video (DB insert after MediaStore save)
4. **Reconciliation job** - Recover from crashes (MediaStore → DB sync)
5. **Thread confinement** - Camera ops on camera thread, not main
6. Replace all `usbFd >= 0` checks with native state queries
7. Add FGS with `connectedDevice` type
8. Stop = state transition + join, not cancel + final drain

---

## Test Build Identification

Builds from this repository are clearly marked as test builds:

```
=== uvccamera-experimental TEST BUILD ===
Build: uvccamera-experimental-<date>-<time>
WARNING: This is a test build, not for production use
```

This distinguishes test builds from scopecam-engine's production builds.

---

*This file is the project-level configuration for Claude Code CLI.*
