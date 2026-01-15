# ARCH-DECISIONS-001-R2: Evidence-Based Architectural Decisions

**Status:** Authoritative (Revision 2)
**Created:** 2026-01-12
**Revised:** 2026-01-12
**Author:** Jeffrey Litecky / Claude
**Project:** ScopeCam - UVCCamera Library Modernization
**Basis:** INVESTIGATION-001 (47 questions), Red Team Reviews, Refined Decisions Session

---

## Revision Notes

### R2 Changes (This Revision)

| Decision | R1 Position | R2 Position |
|----------|-------------|-------------|
| Expected Type | "C++17 compatible" (vague) | **LOCK: tl::expected vendored** |
| Clock Frequency | "read from descriptor" | **LOCK: Already parsed, add fallback** |
| PTS Survey Output | "one JSON per run" | **LOCK: JSONL to file + hybrid validation** |
| Build ID Location | "in libuvc" | **LOCK: JNI bridge + manifest hashes** |
| Callback Migration | "signature change" | **LOCK: Parallel v2 + deprecation window** |
| Quality Ladder | "session-only vs persistent" | **LOCK: Session-only, designed for future** |
| Error Taxonomy | Not specified | **NEW: Hard/Soft with policies** |
| Surface Ownership | "design needed" | **LOCK: Kotlin owns, native provides** |

### R1 Changes (Previous Revision)

Clarified zero-copy boundaries, separated PTS plumbing from correctness, replaced SCHED_FIFO with Android-supported priority, fixed C++17/C++23 standards mismatch, added GET_INFO verification requirement, added runtime caveats to isochronous, operationalized timestamp accuracy.

---

## Executive Summary

The INVESTIGATION-001 findings and subsequent deep-dive reveal a **more mature project than anticipated**. Many features assumed to require implementation already exist. This document establishes binding architectural decisions based on evidence, with refined implementation specifics from the R2 decision session.

### Reality vs. Assumption Matrix (Final)

| Component | Original Assumption | Actual State | R2 Decision |
|-----------|---------------------|--------------|-------------|
| Isochronous Transfer | "Premium path to build" | **CODE EXISTS** | Use with fallback |
| FD Injection | "Required for Android 16" | **COMPLETE** | Verify on API 34+ |
| AHardwareBuffer | "Zero-copy goal" | **AHB→GPU WORKING** | Document boundaries |
| PTS/SCR Timestamps | "libuvc modification needed" | **EXTRACTED** (not connected) | ~5 LOC plumbing + correctness |
| dwClockFrequency | "Need to read descriptor" | **ALREADY PARSED** | Use with fallback |
| GPU Pipeline | "Must build" | **COMPLETE** | Verify flags |
| Frame Assembly | "Robustness unknown" | **ROBUST** | No changes |
| Backpressure | "Need MAILBOX policy" | **IMPLEMENTED** | No changes |
| GET_INFO | "Probably exists" | **NEVER CALLED** | Implement + verify |
| MediaCodec | "Probably exists" | **NOT PRESENT** | Build from scratch |
| Clock Sync | "Probably exists" | **NONE** | Build from scratch |
| Thread Priority | "Probably configured" | **NOT SET** | Android-supported |
| Recovery FSM | "Basic handling" | **DETECTION ONLY** | Build state machine |

---

## Part I: Locked Decisions (Ship-Ready)

These decisions are **final and implementation-ready**.

### DECISION-001: Continue libuvc Fork

**Status:** FINAL
**Evidence:** B-01, B-02, B-03

**Decision:** Continue maintaining the saki@serenegiant fork. Do NOT attempt upstream merge, wrapper abstraction, or complete rewrite.

**Rationale:**
- 60+ libuvc APIs actively used
- 108% code growth (4,277 lines added)
- Android-specific FD injection built in
- Original files preserved as `*_original.c`

---

### DECISION-002: Keep ndk-build

**Status:** FINAL
**Evidence:** G-01, G-02, G-04

**Decision:** Continue using ndk-build with Android.mk/Application.mk. CMake migration is optional.

**Required Enhancement:**
```makefile
APP_CPPFLAGS += -std=c++17
```

---

### DECISION-003: Zero-Copy Infrastructure (Clarified Boundaries)

**Status:** FINAL

**What IS Zero-Copy:**
- AHardwareBuffer → EGLImage
- EGLImage → GL Texture
- GPU Texture → Display

**What is NOT Zero-Copy:**
- USB → libusb buffer (kernel boundary)
- libusb → conversion (MJPEG decode)
- Conversion → AHardwareBuffer (CPU write)

**True Zero-Copy Path (Future):** H.264 → MediaCodec → Surface

---

### DECISION-004: FD Injection is COMPLETE

**Status:** FINAL
**Evidence:** A-02

**Decision:** Close OPP-011. Verify on API 34+ devices.

---

### DECISION-005: Isochronous Code Exists

**Status:** FINAL
**Evidence:** A-01, A-03, A-06

**Decision:** Use existing isochronous paths with fallback to bulk on failure.

---

### DECISION-006: PTS/SCR Plumbing + Correctness (Separated)

**Status:** FINAL (R2 refined)
**Evidence:** D-01, D-02

**Plumbing (~5 LOC):** Connect `strmh->hold_pts` to `frame->pts_raw`

**Clock Frequency (RESOLVED):**
```c
// stream.c:252 - ALREADY PARSED
ctrl->dwClockFrequency = DW_TO_INT(buf + 26);

// Usage with fallback:
uint32_t getClockFrequency(const uvc_stream_ctrl_t* ctrl) {
    if (ctrl->dwClockFrequency > 0 && ctrl->dwClockFrequency < 1000000000) {
        return ctrl->dwClockFrequency;
    }
    LOGW("Clock frequency missing/invalid, using 15MHz default");
    return 15000000;  // Common UVC default
}
```

---

### DECISION-007: Thread Priority (Android-Supported)

**Status:** FINAL

**Approach:**
```c
// Native
setpriority(PRIO_PROCESS, 0, -10);

// Kotlin
Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO);
```

Log requested vs actual, expose in telemetry.

---

### DECISION-008: Backpressure Handling is COMPLETE

**Status:** FINAL

MAILBOX policy implemented and working. No changes needed.

---

### DECISION-009: C++17 Standard

**Status:** FINAL

```makefile
APP_CPPFLAGS += -std=c++17
```

```cpp
static_assert(__cplusplus >= 201703L, "C++17 required");
```

---

### DECISION-010: Frame Assembly is Robust

**Status:** FINAL

No modifications needed.

---

## Part II: R2 Refined Decisions (New Locks)

### DECISION-016: Expected Type — tl::expected (Vendored)

**Status:** FINAL (R2)

**Decision:** Use `tl::expected`, header-only, vendored under `third_party/`, with project alias.

**Implementation:**
```cpp
// nativecode/src/main/cpp/include/uvc/expected.h
#pragma once
#include "third_party/tl/expected.hpp"

namespace uvc {
    template<typename T, typename E>
    using expected = tl::expected<T, E>;

    using tl::unexpected;
    using tl::make_unexpected;
}
```

**Error Type Shape:**
```cpp
enum class UvcError {
    InvalidHandle,
    DeviceDisconnected,
    Timeout,
    TransferFailed,
    ControlStalled,
    UnsupportedFormat,
    ResourceExhausted
};

// Rich context only at boundaries
struct UvcErrorContext {
    UvcError code;
    int errno_value;      // When relevant
    int libusb_error;     // When relevant
    const char* message;  // Static string only (no allocation)
};
```

**Rationale:**
- Battle-tested, widely used, zero runtime cost
- API matches future `std::expected` (C++23)
- Local implementation becomes maintenance burden
- `optional + outparam` spreads error handling

---

### DECISION-017: Build ID in JNI Bridge

**Status:** FINAL (R2)

**Decision:** Build ID symbol lives in JNI bridge .so, reports integration info + prebuilt hashes.

**Implementation:**
```cpp
// Generated at build time: uvc_build_manifest.h
#define UVC_BUILD_GIT_SHA "abc123"
#define UVC_BUILD_TIMESTAMP "2026-01-12T15:30:00Z"
#define UVC_LIBUVC_HASH "sha256:..."
#define UVC_LIBUSB_HASH "sha256:..."
#define UVC_NDK_VERSION "r27"
#define UVC_ABI "arm64-v8a"

// Exposed via JNI
extern "C" const char* uvc_build_id() {
    return "uvccamera:" UVC_BUILD_GIT_SHA "@" UVC_BUILD_TIMESTAMP;
}
```

**Rationale:**
- JNI bridge is what we ship and debug
- Modifying prebuilt libs just for IDs is maintenance tax
- SHA256 hashes provide prebuilt verification

---

### DECISION-018: Callback Signature — Parallel v2

**Status:** FINAL (R2)

**Decision:** Add parallel v2 callback for PTS/SCR, deprecate v1 over 6 months.

**Implementation:**
```cpp
// Old (keep for compatibility window)
typedef void (*captureCallbackFunc_t)(
    void* data, size_t size, int width, int height,
    int format, int64_t timestampNs, void* user);

// New
typedef void (*captureCallbackFunc_v2_t)(
    void* data, size_t size, int width, int height,
    int format, int64_t timestampNs,
    uint32_t ptsRaw, uint32_t scrRaw, uint8_t timestampFlags,
    void* user);

// Registration
void setCaptureCallback(captureCallbackFunc_t cb);      // Deprecated
void setCaptureCallbackV2(captureCallbackFunc_v2_t cb); // Preferred
int getCaptureCallbackApiVersion();                      // Query
```

**Timeline:**
- v2 parallel: Immediate
- v1 deprecated warning: +3 months
- v1 removal: +6 months

**Rationale:**
- Enables rollback without coordinated repo updates
- Clean break is riskier for camera pipelines
- Packing into existing fields causes subtle bugs

---

### DECISION-019: PTS Survey — JSONL to File

**Status:** FINAL (R2)

**Decision:** PTS survey outputs JSONL to app-private storage, with hybrid validation mode.

**Path:**
```
/storage/emulated/0/Android/data/<pkg>/files/
  └── diagnostics/
      └── pts-survey/
          └── {VID}_{PID}_{serial}/
              └── {timestamp}_{format}_{resolution}.jsonl
```

**Record Format:**
```json
{"frameIdx":0,"tsNs":1736712000000000,"pts":12345678,"scr":87654321,"flags":3,"clockHz":15000000,"fmt":"MJPEG","fps":30,"dropped":false}
```

**Validation Mode (Hybrid):**
```kotlin
enum class PtsValidationMode {
    AUTO,           // Runtime heuristics (monotonic for N frames)
    DEVICE_TESTED,  // Passed survey, stored in SharedPrefs
    FORCED_ON,      // User override
    FORCED_OFF      // User override (use host clock)
}
```

**Analysis:** `tools/pts_analyze.py` emits pass/fail with thresholds.

---

### DECISION-020: Quality Ladder — Session-Only

**Status:** FINAL (R2)

**Decision:** Quality ladder state is session-only, designed for future persistence.

**Implementation:**
```kotlin
data class QualityLadderState(
    val currentResolutionIndex: Int,
    val currentFpsIndex: Int,
    val currentFormatIndex: Int,
    val degradationCount: Int,
    val lastDegradationTimeNs: Long
) {
    fun serialize(): String = ...
    companion object {
        fun deserialize(s: String): QualityLadderState = ...
    }
}
```

**Future Persistence Rule (When Added):**
- Persist only "last-known-good max mode" per device
- NOT "we degraded so stay degraded forever"
- User override: "Prefer Quality / Prefer Stability / Manual"

---

### DECISION-021: Error Taxonomy

**Status:** FINAL (R2)

**Decision:** All errors classified as Hard or Soft with explicit policies.

```cpp
enum class ErrorSeverity {
    HARD,   // Cannot continue stream - must stop
    SOFT    // Can recover - drop frame, degrade, retry
};

enum class SoftErrorPolicy {
    RETRY,              // Resubmit transfer
    DEGRADE_QUALITY,    // Step down ladder
    REPORT_ONLY         // Log and continue
};

// Every soft error maps to exactly one policy
struct ErrorClassification {
    UvcError error;
    ErrorSeverity severity;
    SoftErrorPolicy policy;  // Only if SOFT
};
```

**Classification Table:**
| Error | Severity | Policy |
|-------|----------|--------|
| DeviceDisconnected | HARD | N/A |
| ControlStalled | SOFT | RETRY |
| TransferTimeout | SOFT | RETRY (then DEGRADE) |
| FrameCorrupted | SOFT | REPORT_ONLY |
| BandwidthExceeded | SOFT | DEGRADE_QUALITY |
| ResourceExhausted | HARD | N/A |

---

### DECISION-022: MediaCodec Surface Ownership

**Status:** FINAL (R2)

**Decision:** Kotlin owns Surface/MediaCodec lifecycle, native provides data + metadata.

**Boundary Rules:**

| Kotlin Owns | Native Provides |
|-------------|-----------------|
| Surface lifecycle | NAL unit assembly |
| MediaCodec instance | Timestamp metadata |
| Codec configuration | Backpressure signaling |
| Error recovery | Format detection |

**Native MUST NOT:**
- Assume codec state
- Hold Surface references across JNI calls
- Write to Surface after onSurfaceDestroyed

---

## Part III: Decisions Requiring Implementation Design

### DECISION-011: Implement GET_INFO

**Status:** APPROVED, DESIGN + VERIFICATION NEEDED

Implementation and verification requirements unchanged from R1.

---

### DECISION-012: Build MediaCodec H.264/HEVC Pipeline

**Status:** APPROVED, DESIGN SPECIFIED (R2)

**Architecture (Locked):**
```
USB H.264 Payload → NAL Assembly (native) → AU Callback → MediaCodec (Kotlin) → Surface
```

See DECISION-022 for ownership model.

---

### DECISION-013: Build Clock Synchronization

**Status:** APPROVED, DESIGN NEEDED

Use `dwClockFrequency` from stream control (already parsed). Linear regression with confidence metric.

---

### DECISION-014: Build Recovery State Machine

**Status:** APPROVED, DESIGN NEEDED

Integrate with existing RecoveryStrategy (4-level escalation) plus QualityLadder.

---

### DECISION-015: Build Extension Unit Framework

**Status:** APPROVED, DESIGN NEEDED

Use `uvc::expected` (DECISION-016) for all XU operations.

---

## Part IV: Remaining Targeted Investigations

### TARGETED-001: Zero-Copy Allocation Flag Verification

Verify AHardwareBuffer flags match all consumers.

**Effort:** 1 hour

---

### TARGETED-002: PTS Reliability Survey

Run survey with JSONL output per DECISION-019.

**Effort:** 2 hours

---

### TARGETED-003: H.264 NAL Unit Format

Capture raw payloads, identify boundaries and fragmentation.

**Effort:** 4 hours

---

### TARGETED-004: Android API 34+ USB Verification

Test FD injection on Android 14/15/16.

**Effort:** 2 hours

---

### TARGETED-005: Memory Pressure Behavior

Test backgrounding and low-memory conditions.

**Effort:** 2 hours

---

## Part V: Binding Architectural Principles (R2 Updated)

### PRINCIPLE-001: Evidence Over Assumption

Every implementation decision must cite specific evidence from codebase investigation.

### PRINCIPLE-002: Enhance, Don't Replace

When infrastructure exists and works, enhance and optimize rather than rewrite.

### PRINCIPLE-003: Layered Capability Model

- **Universal baseline:** Works on all devices (bulk, MJPEG, host timestamps)
- **Premium path:** Enhanced when available (isochronous, H.264, PTS sync)
- Premium paths must be runtime-detected and revertible without restart

### PRINCIPLE-004: Observable Everything

Every subsystem exposes state, metrics, errors, and effective settings.

### PRINCIPLE-005: Fail Gracefully, Recover Systematically

Errors classified per DECISION-021, recovery per DECISION-014.

### PRINCIPLE-006: Timestamp Accuracy (Operationalized)

Sub-millisecond where hardware supports. Confidence metric exposed. Fallback to host timestamps.

### PRINCIPLE-007: UVC 1.5 Compliance

GET_INFO, frame-based formats, Extension Units, proper error handling.

### PRINCIPLE-008: C ABI Boundary (NEW - R2)

The boundary between libuvc.so and scopecam-engine MUST be C ABI only:

| Allowed | Forbidden |
|---------|-----------|
| JNI functions | std::string |
| POD structs | std::vector |
| Primitive types | C++ exceptions |
| Byte buffers | STL containers |
| Function pointers | C++ objects |

Both repos: same NDK (27.x), same STL (c++_shared), same ABIs.

---

## Part VI: Implementation Contract

### What This Document Authorizes

| Category | Authorization |
|----------|---------------|
| **Locked Decisions (I, II)** | Implement as specified |
| **Design-Needed (III)** | Design phase before implementation |
| **Targeted Investigations (IV)** | Time-boxed research |

### What This Document Prohibits

| Prohibition | Rationale |
|-------------|-----------|
| Using std::expected directly | C++17 binding; use tl::expected |
| Using SCHED_FIFO | Not available to Android apps |
| Claiming "zero-copy" without boundaries | Misleading |
| Shipping GET_INFO without verification | Request packing risk |
| Treating isochronous as "always works" | Runtime-dependent |
| Passing STL types across .so boundary | ABI safety |
| Breaking v1 callback without deprecation | Integration stability |

### Implementation Sequence (Binding)

```
Phase 0-Pre: Integration Infrastructure (Immediate)
├── Build ID in JNI bridge + manifest
├── Sync script with hash verification
├── C++17 flag + static_assert
└── Vendor tl::expected

Phase 0: Immediate Wins + Verification (Week 1)
├── PTS/SCR plumbing (use dwClockFrequency)
├── Callback v2 registration (parallel to v1)
├── Thread priority + logging
├── TARGETED-002: PTS survey (JSONL output)
└── TARGETED-004: Android API 34+ verification

Phase 1: UVC Compliance (Weeks 2-3)
├── Implement GET_INFO
├── Verify against Linux uvcvideo
├── Control range caching
└── Structured error context

Phase 2: Reliability (Weeks 4-5)
├── Clock synchronization (linear regression)
├── Recovery state machine integration
├── Quality ladder (session-only)
└── Error taxonomy enforcement

Phase 3: H.264/HEVC (Weeks 6-9)
├── TARGETED-003: NAL format investigation
├── NAL assembly (native)
├── MediaCodec integration (Kotlin-owned Surface)
└── Recovery integration

Phase 4: XU & Polish (Weeks 10-12)
├── XU framework (uvc::expected)
├── Quirk registry
└── Test harness
```

---

## Part VI: App Integration Decisions (R2.1)

### DECISION-023: Session Truth Model (Native Authority)

**Status:** FINAL (2026-01-14)
**Evidence:** App debugging, FD ownership analysis

**Decision:** When using `openSimple()`, native is the sole owner of USB session truth.

**Background:**
- `openSimple(fd)` passes an FD directly to native, which `dup()`s it
- Native stores the duplicated FD in `mFd` and owns its lifecycle
- Java-layer `mCtrlBlock` is NOT set by `openSimple()`
- Any Java-layer FD checks return invalid/null values

**Contract:**
1. **Kotlin MUST NOT** infer session state from `UsbDeviceConnection.getFileDescriptor()` or `UsbControlBlock`
2. **Kotlin MUST** use `getPreviewState()` / `querySessionDiagnostic()` for session state
3. **Native MUST** provide deterministic diagnostics via `NativeSnapshot` pattern

**Implications:**
- "WARM gate" must use native state, not Java FD checks
- Recording prerequisites must query native (`previewState == HOT`)
- Surface attachment status must be queried from native (`DIAG_SURFACE_BOUND`)

**See:** `patches/SCOPECAM_ENGINE_WARM_GATE_DIRECTIVE.md`

---

### DECISION-024: Recording Contract (HOT Gate)

**Status:** FINAL (2026-01-14)
**Evidence:** Video recording debugging, frames=0 analysis

**Decision:** Recording may start ONLY when HOT gate passes.

**Invariant:**
```
previewState == HOT && surfaceAttached && !stagnant
```

**Contract Behavior:**
1. If invariant passes → start recording
2. If invariant fails → request HOT, await with timeout, then start
3. If timeout → abort with user-actionable error

**First-Frame SLA:** If no frame received within 1s after encoder start, abort and discard (no empty recordings).

**See:** `patches/SCOPECAM_ENGINE_VIDEO_RECORDING_DIRECTIVE.md`

---

### DECISION-025: Capture Commit Pattern (DB-First)

**Status:** FINAL (2026-01-14)
**Evidence:** "Video saved but not visible" bug analysis

**Decision:** Room DB is the source of truth for captured media. MediaStore is the storage backend.

**Capture Commit = MediaStore write + DB insert + Metadata attached**

**Contract:**
1. Both photo AND video MUST use the same `commitCapture()` function
2. If MediaStore succeeds but DB fails, log warning and attempt reconciliation later
3. Reconciliation job runs on app start to sync MediaStore → DB

**See:** `patches/SCOPECAM_ENGINE_VIDEO_RECORDING_DIRECTIVE.md` Part V

---

## Document Control

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-12 | Claude | Initial evidence-based decisions |
| 1.1 | 2026-01-12 | Claude | Red team review corrections |
| 2.0 | 2026-01-12 | Claude | R2: Locked ship-ready decisions |
| **2.1** | **2026-01-14** | **Claude** | **R2.1: App integration decisions** |

**R2 New Decisions:**
- DECISION-016: tl::expected (vendored)
- DECISION-017: Build ID in JNI bridge
- DECISION-018: Callback v2 (parallel + deprecation)
- DECISION-019: PTS survey JSONL + hybrid validation
- DECISION-020: Quality ladder session-only
- DECISION-021: Error taxonomy (Hard/Soft)
- DECISION-022: MediaCodec ownership (Kotlin Surface)
- PRINCIPLE-008: C ABI boundary

**R2.1 New Decisions:**
- DECISION-023: Session Truth Model (Native Authority)
- DECISION-024: Recording Contract (HOT Gate)
- DECISION-025: Capture Commit Pattern (DB-First)

**Locked in R2:** Clock frequency (already parsed), all "Important Decisions" from refinement session.

**Authority:** This document is the binding architectural specification for ScopeCam UVCCamera modernization.

**Amendment Process:** Changes require new evidence and explicit revision of this document.

---

*End of ARCH-DECISIONS-001-R2.1*
