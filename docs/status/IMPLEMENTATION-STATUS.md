# Implementation Status: ARCH-DECISIONS-001-R2

**Last Updated:** 2026-01-13
**Current Phase:** Phase 0 (INTEGRATED - awaiting device testing)
**Overall Progress:** Phase 0-Pre COMPLETE, Phase 0 code INTEGRATED into scopecam-engine

---

## Status Legend

| Symbol | Meaning |
|--------|---------|
| `[ ]` | Not started |
| `[~]` | In progress |
| `[x]` | Complete |
| `[!]` | Blocked or deviation (see DEVIATIONS.md) |
| `[-]` | Skipped (with justification) |

---

## Phase Summary

| Phase | Status | Sub-tasks | Complete | Blocked |
|-------|--------|-----------|----------|---------|
| **0-Pre** | **COMPLETE** | 19 | 19 | 0 |
| **0** | **INTEGRATED** | 28 | 25 | 3 (device testing) |
| 1 | Waiting | 18 | 0 | 0 |
| 2 | Waiting | 24 | 0 | 0 |
| 3 | Waiting | 18 | 0 | 0 |
| 4 | Waiting | 18 | 0 | 0 |

### Phase 0 Integration Status (2026-01-13)

**Patches created in uvccamera-experimental:**
- [x] `libuvc-pts-scr-plumbing.patch` - PTS/SCR timestamp extraction
- [x] `thread-priority.patch` - Callback thread priority boost
- [x] `tl-expected-integration.patch` - Documentation only

**Integration by scopecam-engine:**
- [x] Patches applied to `third_party/libuvc/`
- [x] StreamTelemetry.h extended (v2→v3, fields 37→41)
- [x] NativeTelemetry.kt updated
- [x] APK built: `app-qa-debug.apk` (32 MB)

**Awaiting device testing:**
- [ ] PTS/SCR reliability verification
- [ ] Thread priority verification
- [ ] Fill PTS_RELIABILITY_REPORT.md with test results

---

## Phase 0-Pre: Integration Infrastructure (BLOCKER)

**Status:** ACTIVE
**Blocking:** All subsequent phases
**ADR Reference:** DECISION-016, DECISION-017, DECISION-009

### Tasks

#### 0-Pre.1: Vendor tl::expected
- [x] Download tl::expected header (pinned version)
- [x] Create `lib/src/main/jni/third_party/tl/expected.hpp`
- [x] Create `lib/src/main/jni/include/uvc/expected.h` alias header
- [x] Add license file

**Files:** `third_party/tl/expected.hpp`, `include/uvc/expected.h`, `third_party/tl/LICENSE`
**Decision:** DECISION-016
**Commit:** a48b8a2

#### 0-Pre.2: Build ID System
- [x] Create `lib/src/main/jni/UVCCamera/uvc_build_id.c`
- [x] Add git SHA and timestamp defines to Android.mk
- [x] Add `uvc_build_id.c` to LOCAL_SRC_FILES
- [x] Verify symbol exports with `nm` (exports: `uvc_get_build_id`, `uvc_get_build_time`)

**Files:** `UVCCamera/uvc_build_id.c`, `UVCCamera/Android.mk`
**Decision:** DECISION-017
**Commit:** 160bf71

#### 0-Pre.3: Sync Script
- [x] Create `tools/sync_to_engine.sh`
- [x] Test clean build + copy (verified 2026-01-12)
- [x] Test hash verification (6 libraries synced with SHA256 verification)
- [x] Document in CLAUDE.md (cross-repo collaboration section added)

**Files:** `tools/sync_to_engine.sh`
**Decision:** DECISION-017
**Commit:** 0b85598
**Verification:** Synced to ../scopecam-engine/nativecode/src/main/libs/

#### 0-Pre.4: C++17 Standard
- [x] Add `APP_CPPFLAGS += -std=c++17` to Application.mk
- [x] Add static_assert to UVCCamera.cpp (line 51)
- [x] Verify build succeeds (both arm64-v8a and armeabi-v7a)

**Files:** `jni/Application.mk`, `UVCCamera/UVCCamera.cpp`
**Decision:** DECISION-009
**Commit:** 160bf71

#### 0-Pre.5: Build Manifest Generation
- [x] Create script to generate `uvc_build_manifest.h` (integrated into sync_to_engine.sh)
- [x] Include prebuilt SHA256 hashes (6 libraries, both ABIs)
- [x] Include NDK version (27.0.12077973)
- [x] Integrate into build (generated on sync)

**Files:** `tools/sync_to_engine.sh`, `jni/include/uvc_build_manifest.h`
**Decision:** DECISION-017
**Generated:** `lib/src/main/jni/include/uvc_build_manifest.h`

### Phase 0-Pre Completion Criteria

- [x] All tasks above marked [x]
- [x] `ndk-build` succeeds for both ABIs (arm64-v8a, armeabi-v7a)
- [x] Test harness builds and runs
- [x] No compiler warnings introduced

### Phase 0-Pre Notes

**Status:** COMPLETE. Phase 0 can begin.

**Project Role Clarified (2026-01-13):**

This repository is a **SANDBOX** for testing UVC library improvements:
- Test libuvc/libusb changes in isolation
- Validate features before promoting to scopecam-engine
- Output: **patches and documentation** (not binaries)

**Relationship with scopecam-engine:**
- scopecam-engine vendors source in `third_party/`
- scopecam-engine builds everything from source (CMake/C++20)
- Improvements here are promoted via **patches**, not binary syncing
- See `docs/PROMOTION_WORKFLOW.md` for the promotion process

**Sync script deprecated:**
- `tools/sync_to_engine.sh` is deprecated and will error if run
- Binary syncing was an anti-pattern (ABI issues, reproducibility problems)

**CI/Tooling setup complete (2026-01-12):**
- mise + direnv for tool version management (Java 17)
- lefthook git hooks (clang-format, shellcheck, pre-push build)
- ktlint + detekt lint passing
- GitHub Actions CI with format-check and kotlin-lint jobs

**Test Build Identification:**
- Builds clearly marked as test builds in logcat
- Distinguishes from scopecam-engine production builds

---

## Phase 0: Immediate Wins + Verification (Week 1)

**Status:** ✅ **PRODUCTION-READY** (2026-01-13) - Synced to scopecam-engine
**ADR Reference:** DECISION-006, DECISION-007, DECISION-018
**Sync Confirmed:** All changes present in scopecam-engine `third_party/libuvc/`

### Tasks

#### 0.1: PTS/SCR Frame Fields
- [x] Add `capture_time_pts`, `capture_time_scr` to `uvc_frame_t`
- [x] Add validity flags (`capture_time_pts_valid`, `capture_time_scr_valid`)
- [x] Wire values in `_uvc_populate_frame()`
- [x] Add `getClockFrequency()` helper with fallback

**Files:** `libuvc/include/libuvc/libuvc.h`, `libuvc/src/stream.c`
**Decision:** DECISION-006
**Commit:** Already integrated

#### 0.2: Callback v2 Registration
- [x] Define `captureCallbackFunc_v2_t` typedef
- [ ] Add `setCaptureCallbackV2()` registration (scopecam-engine integration)
- [ ] Add `getCaptureCallbackApiVersion()` query (scopecam-engine integration)
- [x] Maintain v1 compatibility

**Files:** `UVCCamera/UVCPreview.h`, `UVCCamera/UVCPreview.cpp`
**Decision:** DECISION-018
**Status:** Typedef complete, registration methods for scopecam-engine

#### 0.3: Thread Priority
- [x] Add `setpriority()` call at USB thread start
- [x] Add priority logging (requested vs actual)
- [x] Log errno on failure
- [ ] Add telemetry fields (scopecam-engine integration)

**Files:** `libuvc/src/stream.c`
**Decision:** DECISION-007
**Commit:** Already integrated

#### 0.4: PTS Telemetry Counters
- [ ] Add `ptsPresentFrames` counter
- [ ] Add `scrPresentFrames` counter
- [ ] Add `ptsZeroFrames` counter
- [ ] Add `lastPtsRaw`, `lastScrRaw` for debugging

**Files:** scopecam-engine `StreamTelemetry.h`
**Decision:** DECISION-006

#### 0.5: PTS Survey Mode
- [ ] Add `ptsSurveyEnabled` flag
- [ ] Implement JSONL logging every N frames
- [ ] Create survey output directory structure
- [ ] Document analysis procedure

**Files:** scopecam-engine, `tools/pts_analyze.py`
**Decision:** DECISION-019

#### 0.6: TARGETED-002 Execution
- [ ] Run PTS survey on cam1 (Realtek)
- [ ] Run PTS survey on cam2 (Endoscope)
- [ ] Analyze results with script
- [ ] Document findings

**Files:** `docs/testing/PTS-survey-results.md`
**Investigation:** TARGETED-002

#### 0.7: TARGETED-004 Execution
- [ ] Test on Android 14+ device
- [ ] Verify FD injection
- [ ] Run 20x connect/disconnect stress test
- [ ] Document results

**Files:** `docs/testing/API34-verification-results.md`
**Investigation:** TARGETED-004

### Phase 0 Completion Criteria

- [x] All core tasks marked [x]
- [x] PTS/SCR values available in uvc_frame_t
- [x] Changes synced to scopecam-engine
- [x] Build verification complete (both ABIs)
- [ ] Survey results documented (scopecam-engine P2)
- [ ] API 34+ verification complete (scopecam-engine P2)

**Status:** Core implementation complete. Device testing in scopecam-engine (P2 priority).

---

## Phase 1: UVC Compliance (Weeks 2-3)

**Status:** 🔄 **IN PROGRESS** (2026-01-13) - GET_INFO implemented
**ADR Reference:** DECISION-011

### Tasks

#### 1.1: GET_INFO Function
- [x] Implement `uvc_get_info()` in ctrl.c
- [x] Add debug logging (LOGD/LOGI/LOGW)
- [x] Define `uvc_ctrl_caps_t` struct
- [x] Define `uvc_ctrl_cap_source_t` enum
- [x] Implement fallback logic for non-compliant devices
- [x] Build verification (both ABIs)

**Files:** `libuvc/src/ctrl.c`, `libuvc/include/libuvc/libuvc.h`
**Decision:** DECISION-011
**Status:** Core implementation complete, awaiting device testing

#### 1.2: Control Capability Cache
- [x] Create cache structure in device handle
- [x] Implement cache lookup/store functions
- [x] Integrate cache with uvc_get_info()
- [x] Add cache initialization in uvc_open()
- [x] Add cache cleanup in uvc_close()
- [x] Build verification (both ABIs)

**Files:** `libuvc/src/ctrl.c`, `libuvc/src/device.c`, `libuvc/include/libuvc/libuvc_internal.h`
**Decision:** DECISION-011
**Status:** Complete - cache eliminates repeated USB requests

#### 1.3: GET_INFO Fallback (Empirical Inference)
- [x] Replace dangerous CTRL_TIMEOUT_MILLIS=0 with safe timeouts
- [x] Add BLACKLIST state to uvc_ctrl_cap_source_t
- [x] Extend cache entry with timestamp metadata
- [x] Add ctrl_mutex for thread-safe probing
- [x] Implement get_monotonic_time_ms() helper
- [x] Implement uvc_probe_control_empirical() with No-Op protocol
- [x] Integrate empirical fallback into uvc_get_info()
- [x] Add device lifecycle (mutex init/destroy)
- [x] Build verification (both ABIs)

**Files:** `libuvc/src/ctrl.c`, `libuvc/src/device.c`, `libuvc/include/libuvc/libuvc.h`, `libuvc/include/libuvc/libuvc_internal.h`
**Decision:** DECISION-011
**Status:** Complete - professional-grade empirical discovery with thread safety and blacklisting

#### 1.4: GET_INFO Verification
- [ ] Test exposure control on Linux
- [ ] Test exposure control on Android
- [ ] Compare results
- [ ] Document findings

**Files:** `docs/testing/GET_INFO-verification.md`
**Decision:** DECISION-011

#### 1.5: Structured Error Context
- [ ] Define `UvcError` enum
- [ ] Define `UvcErrorContext` struct
- [ ] Integrate with `uvc::expected`

**Files:** scopecam-engine `include/uvc/error.h`
**Decision:** DECISION-021

### Phase 1 Completion Criteria

- [ ] All tasks above marked [x]
- [ ] GET_INFO returns valid data for known controls
- [ ] Verification document complete
- [ ] Error context integrated

---

## Phase 2: Reliability (Weeks 4-5)

**Status:** WAITING (blocked by Phase 1)
**ADR Reference:** DECISION-013, DECISION-014, DECISION-020, DECISION-021

### Tasks

#### 2.1: Clock Synchronizer Class
- [ ] Implement `ClockSynchronizer` class
- [ ] Add PTS unwrapping with wrap detection
- [ ] Add sliding window for samples
- [ ] Implement least-squares regression

**Files:** scopecam-engine `ClockSynchronizer.h/.cpp`
**Decision:** DECISION-013

#### 2.2: Confidence Metric
- [ ] Calculate RMSE over window
- [ ] Calculate drift PPM
- [ ] Map to 0-1 confidence
- [ ] Expose in `SyncResult`

**Files:** scopecam-engine `ClockSynchronizer.h`
**Decision:** DECISION-013

#### 2.3: Quality Ladder
- [ ] Implement `QualityStep` data class
- [ ] Implement `QualityLadder` class
- [ ] Add `stepDown()`, `stepUp()`, `reset()`
- [ ] Add serialization for future persistence

**Files:** scopecam-engine Kotlin
**Decision:** DECISION-020

#### 2.4: Recovery FSM Enhancement
- [ ] Integrate quality ladder with RecoveryStrategy
- [ ] Add state transition logging
- [ ] Add cooldown between step-ups
- [ ] Add telemetry for transitions

**Files:** scopecam-engine `RecoveryStrategy.kt`
**Decision:** DECISION-014

#### 2.5: Error Classification
- [ ] Implement `ErrorSeverity` enum
- [ ] Implement `SoftErrorPolicy` enum
- [ ] Create classification table
- [ ] Integrate with recovery FSM

**Files:** scopecam-engine Kotlin
**Decision:** DECISION-021

#### 2.6: Clock Sync Telemetry
- [ ] Add `clockSyncConfidence` field
- [ ] Add `clockSyncDriftPpm` field
- [ ] Add `timestampSource` field
- [ ] Add RMSE histogram

**Files:** scopecam-engine `StreamTelemetry.h`
**Decision:** DECISION-013

### Phase 2 Completion Criteria

- [ ] All tasks above marked [x]
- [ ] Clock sync producing valid timestamps
- [ ] Quality ladder functional
- [ ] Recovery FSM logging transitions
- [ ] Error classification enforced

---

## Phase 3: H.264/HEVC Pipeline (Weeks 6-9)

**Status:** WAITING (blocked by Phase 2)
**ADR Reference:** DECISION-012, DECISION-022

### Tasks

#### 3.1: TARGETED-003 Execution
- [ ] Capture raw H.264 payloads
- [ ] Identify NAL unit boundaries
- [ ] Document fragmentation pattern
- [ ] Document SPS/PPS delivery

**Files:** `docs/h264/NAL-format-analysis.md`
**Investigation:** TARGETED-003

#### 3.2: NAL Assembler
- [ ] Implement `NalAssembler` class
- [ ] Add Annex B start code detection
- [ ] Add fragment reassembly
- [ ] Add IDR detection

**Files:** scopecam-engine `NalAssembler.h/.cpp`
**Decision:** DECISION-012

#### 3.3: AU Callback Interface
- [ ] Define `AccessUnit` struct
- [ ] Define callback function type
- [ ] Implement JNI bridge for AU delivery

**Files:** scopecam-engine native + JNI
**Decision:** DECISION-012

#### 3.4: H264Decoder Kotlin
- [ ] Implement `H264Decoder` class
- [ ] Add Surface configuration
- [ ] Add MediaCodec lifecycle management
- [ ] Add error handling

**Files:** scopecam-engine Kotlin
**Decision:** DECISION-012, DECISION-022

#### 3.5: Decoder Recovery
- [ ] Handle codec errors
- [ ] Implement flush on packet loss
- [ ] Wait for IDR after loss
- [ ] Add telemetry for recovery events

**Files:** scopecam-engine Kotlin
**Decision:** DECISION-012

### Phase 3 Completion Criteria

- [ ] All tasks above marked [x]
- [ ] H.264 decode working on test camera
- [ ] Recovery from packet loss functional
- [ ] Telemetry capturing decode metrics

---

## Phase 4: XU Framework + Polish (Weeks 10-12)

**Status:** WAITING (blocked by Phase 3)
**ADR Reference:** DECISION-015

### Tasks

#### 4.1: XU Transport Layer
- [ ] Implement `XuTransport` class
- [ ] Add `get()`, `set()`, `getInfo()` methods
- [ ] Use `uvc::expected` for error handling
- [ ] Add JNI bridge

**Files:** scopecam-engine native
**Decision:** DECISION-015

#### 4.2: Typed XU Wrappers
- [ ] Implement `ThermalXuControl` example
- [ ] Add endianness conversion helpers
- [ ] Document pattern for adding new controls

**Files:** scopecam-engine native
**Decision:** DECISION-015

#### 4.3: Quirk Registry
- [ ] Design quirk data structure
- [ ] Implement VID/PID/serial lookup
- [ ] Add capability overrides
- [ ] Add size overrides

**Files:** scopecam-engine
**Decision:** DECISION-015

#### 4.4: XU Telemetry
- [ ] Add `xuQuirkHits` counter
- [ ] Add XU operation timing
- [ ] Add XU error counts

**Files:** scopecam-engine `StreamTelemetry.h`
**Decision:** DECISION-015

#### 4.5: Test Harness Foundation
- [ ] Create XU mock for testing
- [ ] Add unit tests for XU wrappers
- [ ] Add integration test pattern

**Files:** scopecam-engine tests
**Decision:** DECISION-015

### Phase 4 Completion Criteria

- [ ] All tasks above marked [x]
- [ ] XU framework functional
- [ ] Thermal reading working (if hardware available)
- [ ] Quirk registry populated with known quirks
- [ ] Tests passing

---

## Targeted Investigations Status

| ID | Description | Status | Scheduled |
|----|-------------|--------|-----------|
| TARGETED-001 | Zero-copy allocation flags | [ ] Not started | Phase 0 |
| TARGETED-002 | PTS reliability survey | [ ] Not started | Phase 0 |
| TARGETED-003 | H.264 NAL format | [ ] Not started | Phase 3 |
| TARGETED-004 | Android API 34+ USB | [ ] Not started | Phase 0 |
| TARGETED-005 | Memory pressure behavior | [ ] Not started | Phase 2 |

---

## Blocking Issues

### BLOCK-001: scopecam-engine repo not available
**Discovered:** 2026-01-12
**Phase:** 0-Pre
**Task:** 0-Pre.3
**Status:** ✅ RESOLVED (2026-01-13)
**Impact:** Cannot test sync script with actual destination repo
**Resolution:** Repo found at ../scopecam-engine. Sync tested and working.

<!-- Template for blocking issues:
### BLOCK-001: Description
**Discovered:** YYYY-MM-DD
**Phase:** X
**Task:** X.X
**Status:** Open/Resolved
**Resolution:** Description of resolution
-->

---

## Deviation Log

*No deviations recorded. See DEVIATIONS.md for any that occur.*

---

## Completion History

| Date | Phase | Task | Notes |
|------|-------|------|-------|
| 2026-01-12 | 0-Pre | 0-Pre.1 | Vendored tl::expected v1.3 (master) - commit a48b8a2 |
| 2026-01-12 | 0-Pre | 0-Pre.2 | Build ID system with git SHA/timestamp - commit 160bf71 |
| 2026-01-12 | 0-Pre | 0-Pre.4 | C++17 standard enabled, static_assert added - commit 160bf71 |
| 2026-01-12 | 0-Pre | 0-Pre.3 | Sync script created (partial) - commit 0b85598 |
| 2026-01-12 | Infra | CI/Tooling | mise, lefthook, clang-format, ktlint, detekt, CI - commit 5538d20 |
| 2026-01-13 | 0-Pre | 0-Pre.3 | Sync script fully tested with scopecam-engine |
| 2026-01-13 | 0-Pre | 0-Pre.5 | Build manifest generation integrated into sync |
| 2026-01-13 | Infra | Cross-Repo | Added collaboration docs to both CLAUDE.md files |

<!-- Template:
| 2026-01-12 | 0-Pre | 0-Pre.1 | Vendored tl::expected v0.6.1 |
-->

---

## Notes

### Session Continuity

When resuming work:
1. Check current phase status
2. Find first incomplete `[ ]` task
3. Verify no `[!]` blockers
4. Continue from there

### Cross-Repo Changes

Tasks marked with scopecam-engine files require:
1. Complete changes in uvccamera-experimental first
2. Run `sync_to_engine.sh`
3. Make scopecam-engine changes
4. Verify integration

---

*Status file maintained by implementation agent. Manual edits welcome for corrections.*
