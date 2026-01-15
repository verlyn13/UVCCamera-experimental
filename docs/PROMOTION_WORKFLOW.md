# Patch Promotion Workflow

## Overview

uvccamera-experimental is a **sandbox** for testing UVC library improvements.
When changes are validated here, they are promoted to scopecam-engine via **patches** (source-to-source), never as binaries.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       uvccamera-experimental                                │
│                                                                             │
│  PURPOSE: Testing sandbox for UVC library improvements                      │
│                                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐            │
│  │ libuvc (fork)   │  │ libusb (fork)   │  │ libjpeg-turbo   │            │
│  │                 │  │                 │  │    (fork)       │            │
│  │ • PTS/SCR dev   │  │ • USB debugging │  │ • Perf testing  │            │
│  │ • GET_INFO dev  │  │                 │  │                 │            │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘            │
│           │                    │                    │                      │
│           └────────────────────┼────────────────────┘                      │
│                                │                                           │
│                                ▼                                           │
│                    ┌───────────────────────┐                               │
│                    │    Test Harness App   │                               │
│                    │   (local testing)     │                               │
│                    └───────────────────────┘                               │
│                                                                             │
│  OUTPUTS:                                                                   │
│  • patches/*.patch (source patches)                                        │
│  • docs/*.md (change documentation)                                        │
│  • Test results and validation reports                                     │
│                                                                             │
│  NOT OUTPUTS:                                                               │
│  • Production binaries                                                      │
│  • .so files for other projects                                            │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
                                   │ Patch promotion (manual, reviewed)
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          scopecam-engine                                    │
│                                                                             │
│  PURPOSE: Production camera engine                                          │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ third_party/ (VENDORED SOURCE)                                      │   │
│  │                                                                     │   │
│  │  libuvc/     ← Upstream + applied patches                           │   │
│  │  libusb/     ← Upstream + applied patches                           │   │
│  │  libjpeg-turbo/ ← Upstream                                          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                   │                                         │
│                                   │ builds (CMake, C++20)                   │
│                                   ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ libscopecam-engine.so                                               │   │
│  │                                                                     │   │
│  │ • OutputMode state machine                                          │   │
│  │ • FrameBufferRing (AHardwareBuffer)                                 │   │
│  │ • JNI bridge (RegisterNatives)                                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  OWNS:                                                                      │
│  • Its own build system (CMake)                                            │
│  • Its own build ID / provenance                                           │
│  • Decision to apply patches                                               │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Step-by-Step Promotion Process

### Step 1: Develop and Test in uvccamera-experimental

```bash
# Make changes to libuvc
cd lib/src/main/jni/libuvc
vim src/stream.c  # Example: Add PTS/SCR parsing

# Build the test harness
cd ../../../..
./gradlew :lib:assembleDebug

# Install and test on device
./gradlew :app:installDebug
adb logcat | grep -E "(UVC|PTS|SCR)"
```

**Testing requirements before promotion:**
- [ ] Feature works with target hardware (e.g., Realtek 0BDA:5880)
- [ ] No regression in existing functionality
- [ ] Build succeeds for both arm64-v8a and armeabi-v7a
- [ ] Documented test procedure and results

### Step 2: Create Patch File

**Option A: Single commit patch (preferred)**
```bash
cd lib/src/main/jni/libuvc
git add -A
git commit -m "feat: Add PTS/SCR timestamp extraction from UVC payload"
git format-patch -1 HEAD --stdout > ~/patches/libuvc-pts-scr.patch
```

**Option B: Diff against baseline**
```bash
cd lib/src/main/jni/libuvc
git diff origin/main > ~/patches/libuvc-pts-scr.patch
```

**Option C: Multiple commits as patch series**
```bash
cd lib/src/main/jni/libuvc
git format-patch origin/main -o ~/patches/
# Creates 0001-xxx.patch, 0002-xxx.patch, etc.
```

### Step 3: Document the Change

Create a companion markdown file for each patch:

**Example: `libuvc-pts-scr.md`**

```markdown
# PTS/SCR Timestamp Extraction

## Summary

Adds parsing of Presentation Time Stamp (PTS) and Source Clock Reference (SCR)
from UVC payload headers per USB Video Class 1.5 specification.

## Files Changed

| File | Change |
|------|--------|
| `src/stream.c` | Parse PTS/SCR in `_uvc_process_payload()` |
| `include/libuvc/libuvc.h` | Add `pts`, `scr`, `pts_valid`, `scr_valid` fields to `uvc_frame_t` |

## Testing

- **Device**: Realtek 0BDA:5880
- **Test procedure**: Streamed 1080p30 for 10 minutes
- **Results**:
  - PTS present: 98.7% of frames
  - SCR present: 100% of frames
  - Timestamps increment monotonically
  - No frame drops or crashes

## Usage in scopecam-engine

```cpp
void on_frame(uvc_frame_t* frame) {
    if (frame->pts_valid) {
        int64_t presentation_time = frame->pts;
        // Use for A/V sync, frame timing, etc.
    }
}
```

## Breaking Changes

None. New fields are additive.

## ADR Reference

Implements DECISION-006 from ARCH-DECISIONS-001-R2.
```

### Step 4: Submit to scopecam-engine

1. **Open an issue or PR** in the scopecam-engine repository
2. **Attach**:
   - Patch file(s)
   - Documentation markdown
   - Test results/logs
3. **scopecam-engine team reviews**:
   - Code review of the patch
   - Verify it applies cleanly to vendored source
   - Integration testing in their build

### Step 5: scopecam-engine Applies the Patch

```bash
# In scopecam-engine
cd nativecode/src/main/cpp/third_party/libuvc
git apply ../../../patches/libuvc-pts-scr.patch

# Rebuild
./gradlew :nativecode:assembleRelease

# Full regression testing
```

---

## What NOT to Do

| Anti-Pattern | Why It's Wrong | Correct Approach |
|--------------|----------------|------------------|
| Sync prebuilt .so files | Binary dependency hell, ABI issues | Source patches |
| Modify scopecam-engine's third_party/ directly | Changes untested in isolation | Test here first |
| Skip documentation | Future maintainers won't understand | Always document |
| Push untested patches | Breaks production | Full testing required |
| Use git submodules | CI nightmares | Vendored source + patches |

---

## Patch File Naming Convention

```
<library>-<feature>[-<version>].patch
```

**Examples:**
- `libuvc-pts-scr.patch`
- `libuvc-get-info-v2.patch`
- `libusb-timeout-fix.patch`

**For patch series:**
```
0001-libuvc-add-pts-field.patch
0002-libuvc-add-scr-field.patch
0003-libuvc-wire-timestamps-in-stream.patch
```

---

## Deliverables Checklist

For each promoted change:

- [ ] **Patch file**: Clean, applies without conflicts
- [ ] **Documentation**: What, why, how to use
- [ ] **Test evidence**: Logs, results, hardware tested
- [ ] **ADR reference**: Which decision this implements (if applicable)
- [ ] **Breaking changes**: Clearly documented if any

---

## Questions?

If the promotion workflow is unclear, open an issue in this repository for clarification.
