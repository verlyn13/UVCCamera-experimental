# Implementation Status: ARCH-DECISIONS-001-R2

**Last Updated:** 2026-01-12
**Current Phase:** Phase 0-Pre (BLOCKER)
**Overall Progress:** 11/58 tasks complete

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

| Phase | Status | Tasks | Complete | Blocked |
|-------|--------|-------|----------|---------|
| **0-Pre** | **ACTIVE** | 7 | 11 | 0 |
| 0 | Waiting | 12 | 0 | 0 |
| 1 | Waiting | 10 | 0 | 0 |
| 2 | Waiting | 11 | 0 | 0 |
| 3 | Waiting | 10 | 0 | 0 |
| 4 | Waiting | 8 | 0 | 0 |

---

## Phase 0-Pre: Integration Infrastructure (BLOCKER)

**Status:** ACTIVE
**Blocking:** All subsequent phases
**ADR Reference:** DECISION-016, DECISION-017, DECISION-009

### Tasks

#### 0-Pre.1: Vendor tl::expected
- [x] Download tl::expected header (pinned version)
- [x] Create `lib/src/main/jni/third_party/tl/expected.hpp`
- [x] Create `uvc/expected.h` alias header
- [x] Add license file

**Files:** `third_party/tl/expected.hpp`, `include/uvc/expected.h`
**Decision:** DECISION-016

#### 0-Pre.2: Build ID System
- [x] Create `lib/src/main/jni/UVCCamera/uvc_build_id.c`
- [x] Add git SHA and timestamp defines to Android.mk
- [x] Add `uvc_build_id.c` to LOCAL_SRC_FILES
- [x] Verify symbol exports with `nm`

**Files:** `UVCCamera/uvc_build_id.c`, `UVCCamera/Android.mk`
**Decision:** DECISION-017

#### 0-Pre.3: Sync Script
- [x] Create `tools/sync_to_engine.sh`
- [~] Test clean build + copy
- [ ] Test hash verification
- [x] Document in README or CLAUDE.md

**Files:** `tools/sync_to_engine.sh`
**Decision:** DECISION-017

#### 0-Pre.4: C++17 Standard
- [x] Add `APP_CPPFLAGS += -std=c++17` to Application.mk
- [x] Add static_assert to UVCCamera.cpp
- [x] Verify build succeeds

**Files:** `jni/Application.mk`, `UVCCamera/UVCCamera.cpp`
**Decision:** DECISION-009

#### 0-Pre.5: Build Manifest Generation
- [ ] Create script to generate `uvc_build_manifest.h`
- [ ] Include prebuilt SHA256 hashes
- [ ] Include NDK version
- [ ] Integrate into build

**Files:** `tools/generate_manifest.sh`, `include/uvc_build_manifest.h`
**Decision:** DECISION-017

### Phase 0-Pre Completion Criteria

- [ ] All tasks above marked [x]
- [x] `ndk-build` succeeds for both ABIs
- [ ] `sync_to_engine.sh` runs without errors
- [ ] scopecam-engine app logs correct build ID
- [x] No compiler warnings introduced

---

## Phase 0: Immediate Wins + Verification (Week 1)

**Status:** WAITING (blocked by Phase 0-Pre)
**ADR Reference:** DECISION-006, DECISION-007, DECISION-018

### Tasks

#### 0.1: PTS/SCR Frame Fields
- [ ] Add `pts_raw`, `scr_raw`, `ts_flags` to `uvc_frame_t`
- [ ] Define `UVC_TS_*` flag constants
- [ ] Wire values in `_uvc_swap_buffers()`
- [ ] Add `getClockFrequency()` helper with fallback

**Files:** `libuvc/include/libuvc/libuvc.h`, `libuvc/src/stream.c`
**Decision:** DECISION-006

#### 0.2: Callback v2 Registration
- [ ] Define `captureCallbackFunc_v2_t` typedef
- [ ] Add `setCaptureCallbackV2()` registration
- [ ] Add `getCaptureCallbackApiVersion()` query
- [ ] Maintain v1 compatibility

**Files:** `UVCCamera/UVCPreview.h`, `UVCCamera/UVCPreview.cpp`
**Decision:** DECISION-018

#### 0.3: Thread Priority
- [ ] Add `setpriority()` call at USB thread start
- [ ] Add `pthread_setname_np()` for thread naming
- [ ] Log requested vs actual priority
- [ ] Add telemetry fields

**Files:** `libuvc/src/stream.c`
**Decision:** DECISION-007

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

- [ ] All tasks above marked [x]
- [ ] PTS/SCR values visible in telemetry
- [ ] Callback v2 working in scopecam-engine
- [ ] Survey results documented
- [ ] API 34+ verification complete

---

## Phase 1: UVC Compliance (Weeks 2-3)

**Status:** WAITING (blocked by Phase 0)
**ADR Reference:** DECISION-011

### Tasks

#### 1.1: GET_INFO Function
- [ ] Implement `uvc_get_info()` in ctrl.c
- [ ] Add debug logging of setup packet
- [ ] Define `uvc_ctrl_caps_t` struct
- [ ] Add `uvc_parse_ctrl_caps()` helper

**Files:** `libuvc/src/ctrl.c`, `libuvc/include/libuvc/libuvc.h`
**Decision:** DECISION-011

#### 1.2: Control Capability Cache
- [ ] Create cache structure in device handle
- [ ] Implement cache invalidation triggers
- [ ] Add telemetry for cache hits/misses

**Files:** `libuvc/src/ctrl.c`, `libuvc/include/libuvc/libuvc_internal.h`
**Decision:** DECISION-011

#### 1.3: GET_INFO Fallback
- [ ] Handle timeout/stall gracefully
- [ ] Implement empirical inference from GET_CUR/SET_CUR
- [ ] Add `ctrl_cap_source_t` tracking

**Files:** `libuvc/src/ctrl.c`
**Decision:** DECISION-011

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

*No blocking issues currently.*

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
| 2026-01-12 | 0-Pre | 0-Pre.1 | Vendored tl::expected v1.3 (master) |
| 2026-01-12 | 0-Pre | 0-Pre.2 | Build ID system with git SHA/timestamp |
| 2026-01-12 | 0-Pre | 0-Pre.4 | C++17 standard enabled, static_assert added |

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
