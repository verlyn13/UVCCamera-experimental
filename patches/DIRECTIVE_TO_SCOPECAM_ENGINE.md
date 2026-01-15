# Directive: uvccamera-experimental → scopecam-engine

> **⚠️ STATUS: HISTORICAL**
> 
> This directive (2026-01-13) covers Phase 0 patch handoff only.
> 
> **Current binding directives:**
> - `SCOPECAM_ENGINE_WARM_GATE_DIRECTIVE.md` (R2) - Surface lease, FD truth
> - `SCOPECAM_ENGINE_VIDEO_RECORDING_DIRECTIVE.md` (R3) - Recording, capture commit

**Date:** 2026-01-13
**From:** uvccamera-experimental (testing sandbox)
**To:** scopecam-engine (production engine)
**Re:** Phase 0 Patch Status and Handoff Protocol

---

## Executive Summary

uvccamera-experimental has completed **code implementation** for all Phase 0 deliverables. Patches are ready for device testing. This directive establishes the handoff protocol and sets expectations for integration.

---

## 1. Repository Roles (Established)

| Repository | Role | Outputs |
|------------|------|---------|
| **uvccamera-experimental** | Testing sandbox | Patches, documentation, test reports |
| **scopecam-engine** | Production engine | `libscopecam-engine.so`, runtime verification |

**Key principle:** uvccamera-experimental produces **source patches**, never binaries. scopecam-engine owns its build, applies patches at its discretion, and performs final integration testing.

---

## 2. Phase 0 Deliverables Status

### 2.1 PTS/SCR Timestamp Plumbing (TARGETED-002)

**Implementation:** ✅ Complete

| Component | File | Change |
|-----------|------|--------|
| Frame structure | `libuvc.h` | Added `capture_time_pts`, `capture_time_scr`, validity flags |
| Internal tracking | `libuvc_internal.h` | Added `pts_valid`, `scr_valid` to stream handle |
| Parsing & population | `stream.c` | Set validity during parse, populate in `_uvc_populate_frame` |

**Patch file:** `patches/libuvc-pts-scr-plumbing.patch` (156 lines)

**API addition (additive, non-breaking):**
```c
typedef struct uvc_frame {
    // ... existing fields ...
    uint32_t capture_time_pts;        // PTS from UVC header (90kHz ticks)
    uint32_t capture_time_scr;        // SCR from UVC header
    uint8_t capture_time_pts_valid;   // Non-zero if PTS valid
    uint8_t capture_time_scr_valid;   // Non-zero if SCR valid
    // ... existing fields ...
} uvc_frame_t;
```

**Documentation:** `docs/PTS_SCR_PLUMBING.md`

**Test status:** ⏳ Awaiting device testing with USB cameras

---

### 2.2 Thread Priority Boost (DECISION-007)

**Implementation:** ✅ Complete

| Component | File | Change |
|-----------|------|--------|
| Priority setting | `stream.c` | `setpriority(PRIO_PROCESS, 0, -10)` in callback thread |
| Includes | `stream.c` | Added `<sys/resource.h>`, `<errno.h>` |

**Patch file:** `patches/thread-priority.patch`

**Runtime logging (for verification):**
```
UVC callback thread priority: prev=0, requested=-10, actual=-10, result=0, errno=0
```

**Documentation:** `docs/THREAD_PRIORITY.md`

**Test status:** ⏳ Awaiting device verification via logcat

---

### 2.3 tl::expected Integration (DECISION-016)

**Implementation:** ✅ Already integrated (no patch needed)

| Component | File | Status |
|-----------|------|--------|
| Vendored library | `third_party/tl/expected.hpp` | Present |
| UVC wrapper | `include/uvc/expected.h` | Present |

**Documentation:** `docs/EXPECTED_USAGE.md`

**Note:** This is documentation-only for scopecam-engine. The library exists in uvccamera-experimental for sandbox testing. scopecam-engine should vendor its own copy if needed.

---

## 3. Testing Requirements Before Integration

### 3.1 PTS/SCR Reliability Testing

**Test matrix (minimum):**

| Camera | Vendor ID | Product ID | Resolution | Frame Rate | PTS Valid? | Monotonic? |
|--------|-----------|------------|------------|------------|------------|------------|
| Camera 1 | 0x____ | 0x____ | ____x____ | ____fps | [ ] | [ ] |
| Camera 2 | 0x____ | 0x____ | ____x____ | ____fps | [ ] | [ ] |

**Success criteria:**
- PTS present in ≥90% of frames
- PTS strictly monotonic (allowing wraparound)
- PTS delta consistent with frame rate (±10%)
- No garbage values (0x00000000, 0xFFFFFFFF)

**Test report template:** `docs/PTS_RELIABILITY_REPORT.md`

### 3.2 Thread Priority Testing

**Verification:**
```bash
adb logcat -s "libuvc/stream:I" | grep "thread priority"
```

**Success criteria:**
- `actual` priority is negative (boosted from 0)
- `result=0` (success)
- `errno=0` (no error)

---

## 4. Handoff Options

### Option A: Full Testing Before Handoff (Preferred)

1. uvccamera-experimental performs device testing
2. Fills in `PTS_RELIABILITY_REPORT.md` with actual results
3. Submits patches with verification evidence
4. scopecam-engine reviews and applies

**Timeline:** Blocked on device access

### Option B: Provisional Handoff

1. uvccamera-experimental submits patches with "provisional" status
2. scopecam-engine applies to feature branch
3. scopecam-engine performs device testing
4. Move to `patches/applied/` after verification

**Risk:** Testing responsibility shifts to scopecam-engine

### Option C: Parallel Testing

1. Both repositories test independently
2. Compare results for validation
3. Proceed when both confirm success

---

## 5. Integration Instructions for scopecam-engine

When patches are accepted:

### Step 1: Receive Patches
```bash
# Copy to incoming directory
cp uvccamera-experimental/patches/libuvc-pts-scr-plumbing.patch \
   scopecam-engine/nativecode/src/main/cpp/patches/incoming/

cp uvccamera-experimental/patches/thread-priority.patch \
   scopecam-engine/nativecode/src/main/cpp/patches/incoming/
```

### Step 2: Apply to Vendored Source
```bash
cd scopecam-engine/nativecode/src/main/cpp/third_party/libuvc
git apply ../../patches/incoming/libuvc-pts-scr-plumbing.patch
git apply ../../patches/incoming/thread-priority.patch
```

### Step 3: Extend StreamTelemetry.h
```cpp
// Add to TelemetryField enum (append, don't reorder):
CAPTURE_TIME_PTS = 37,
CAPTURE_TIME_SCR = 38,
CAPTURE_TIME_PTS_VALID = 39,
CAPTURE_TIME_SCR_VALID = 40,

// Bump version:
static constexpr uint32_t CURRENT_VERSION = 3;

// Update packForJni() to include new fields
```

### Step 4: Update NativeTelemetry.kt
```kotlin
// Add field indices:
const val CAPTURE_TIME_PTS = 37
const val CAPTURE_TIME_SCR = 38
const val CAPTURE_TIME_PTS_VALID = 39
const val CAPTURE_TIME_SCR_VALID = 40

// Update BUFFER_SIZE accordingly
```

### Step 5: Build and Verify
```bash
./gradlew :nativecode:assembleDebug
# Run on device, verify telemetry includes PTS/SCR
```

### Step 6: Move Patches to Applied
```bash
mv patches/incoming/*.patch patches/applied/
```

---

## 6. Communication Protocol

### From uvccamera-experimental:
- Patches submitted via `patches/` directory
- Documentation in `docs/`
- Status updates via `patches/SUBMISSION_STATUS.md`

### From scopecam-engine:
- Integration status updates
- Any issues applying patches
- Device test results (if performing Option B)

### Blocking notifications:
- Either repository can declare "BLOCKED" status
- Must include: what's blocked, what's needed to unblock

---

## 7. Current Blocking Status

```
┌─────────────────────────────────────────────────────────────┐
│  uvccamera-experimental: BLOCKED on device testing          │
│                                                             │
│  Reason: Physical USB camera hardware required              │
│  Action needed: Human performs device testing OR            │
│                 scopecam-engine accepts provisional patches │
└─────────────────────────────────────────────────────────────┘
```

---

## 8. Files Included in This Submission

```
patches/
├── DIRECTIVE_TO_SCOPECAM_ENGINE.md   # This document
├── SUBMISSION_STATUS.md              # Detailed status and test instructions
├── libuvc-pts-scr-plumbing.patch     # PTS/SCR implementation (156 lines)
├── thread-priority.patch             # Thread priority boost
└── tl-expected-integration.patch     # Documentation reference

docs/
├── PTS_SCR_PLUMBING.md               # Technical specification
├── PTS_RELIABILITY_REPORT.md         # Test report template (needs data)
├── THREAD_PRIORITY.md                # Technical specification
├── EXPECTED_USAGE.md                 # tl::expected usage guide
└── PROMOTION_WORKFLOW.md             # General patch workflow
```

---

## 9. Decision Required

**Question for project owner:**

How should we proceed?

- [ ] **A.** I will perform device testing and provide results
- [ ] **B.** scopecam-engine should accept provisional patches and test
- [ ] **C.** Wait until device hardware is available
- [ ] **D.** Other: _____________

---

**End of Directive**

*uvccamera-experimental remains in WAIT state pending decision.*
