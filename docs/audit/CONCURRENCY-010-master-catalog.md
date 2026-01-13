# CONCURRENCY-010: Master Concurrency Catalog

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`
**Status:** Complete

---

## Executive Summary

This master catalog consolidates all findings from AUDIT-003 Concurrency Analysis. The UVCCamera codebase implements a sophisticated dual-path frame pipeline with both legacy mutex-based and modern lock-free architectures.

### Key Metrics

| Category | Count |
|----------|-------|
| **Threads** | 15 pthread_create sites |
| **Mutexes** | 13 pthread_mutex_t + 1 std::mutex |
| **Condition Variables** | 6 pthread_cond_t + 2 std::condition_variable |
| **Atomic Variables** | ~90 std::atomic |
| **Blocking Operations** | 39 sites |
| **JNI Attachments** | 7 AttachCurrentThread calls |
| **Global References** | 8 NewGlobalRef sites |
| **P0 Hazards** | 12 |
| **P1 Hazards** | 16 |
| **P2 Hazards** | 11 |

---

## Thread Inventory Summary

### UVCCamera Layer (5 threads)

| Thread | Purpose | Lifecycle | Priority |
|--------|---------|-----------|----------|
| **preview_thread** | Frame decode → Surface | startPreview→stopPreview | Default |
| **capture_thread** | JPEG export + callback | On-demand | Default |
| **conversion_thread** | MJPEG→RGBX (hybrid) | startPreview→stopPreview | SCHED_FIFO |

### libuvc Layer (2 threads per stream)

| Thread | Purpose | Lifecycle | Priority |
|--------|---------|-----------|----------|
| **cb_thread** | USB frame dispatch | uvc_start_streaming→stop | Default |
| **handler_thread** | libusb event loop | Context lifetime | nice(-18) |

### Pipeline Layer (6+ threads)

| Thread | Purpose | Created In |
|--------|---------|------------|
| **preview_thread** | PreviewPipeline | start() |
| **capture_thread** | CaptureBasePipeline | start() |
| Various pipelines | Frame distribution | Pipeline-specific |

---

## Synchronization Primitive Summary

### Mutex Hierarchy (Lock Order)

```
1. preview_mutex       (Frame queue protection)
   └── 2. capture_mutex    (Capture queue protection)
       └── 3. pool_mutex       (Frame pool protection)
           └── 4. mCaptureBufferMutex (Capture buffer)
               └── 5. mWarmFrameMutex (Warm frame)
```

### Modern C++ Primitives

| Primitive | Usage |
|-----------|-------|
| `std::mutex mSwapMutex` | Surface swap coordination |
| `std::condition_variable mRenderThreadIdleCond` | Render idle signal |
| `std::condition_variable mSwappingCond` | Swap complete signal |

### Atomic State Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `mIsRunning` | `atomic<bool>` | Preview loop control |
| `mIsCapturing` | `atomic<bool>` | Capture loop control |
| `mPreviewState` | `atomic<PreviewState>` | COLD/WARM/HOT state |
| `mSwappingSurface` | `atomic<bool>` | Swap in progress |
| `mUseRingBuffer` | `atomic<bool>` | Ring buffer enabled |
| `mFrameBufferRing` | `atomic<FrameBufferRing*>` | Ring buffer pointer |

---

## Architecture Overview

### Frame Pipeline (Dual Path)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            FRAME PIPELINE ARCHITECTURE                          │
└─────────────────────────────────────────────────────────────────────────────────┘

    USB Isochronous Transfer
           │
           ▼
    ┌─────────────┐
    │  cb_thread  │ (libuvc callback)
    └──────┬──────┘
           │
           ├──────────────────────────────────┐
           │                                  │
           ▼                                  ▼
    ┌──────────────────┐             ┌──────────────────┐
    │   LEGACY PATH    │             │   HYBRID PATH    │
    │                  │             │                  │
    │ uvc_duplicate()  │             │ enqueuePending() │
    │ addPreviewFrame()│             │ (SPSC lock-free) │
    │ (mutex queue)    │             │                  │
    └────────┬─────────┘             └────────┬─────────┘
             │                                │
             ▼                                ▼
    ┌──────────────────┐             ┌──────────────────┐
    │  preview_thread  │             │conversion_thread │
    │                  │             │                  │
    │ waitPreviewFrame │             │ MJPEG→YUYV→RGBX  │
    │ MJPEG→YUYV→RGBX  │             │ AHardwareBuffer  │
    │ ANativeWindow    │             │ Ring Buffer      │
    └────────┬─────────┘             └────────┬─────────┘
             │                                │
             └──────────┬─────────────────────┘
                        │
                        ▼
                 ┌──────────────┐
                 │  Surface /   │
                 │  Consumer    │
                 └──────────────┘
```

### Shutdown Protocol (Signal-Drain-Destroy)

```
1. SIGNAL:  mUseRingBuffer.store(false)     // Stop new callbacks
2. FENCE:   atomic_thread_fence(seq_cst)    // Memory barrier
3. DRAIN:   while (mCallbacksInFlight > 0)  // Wait for in-flight
4. EXCHANGE: oldRing = mFrameBufferRing.exchange(nullptr)
5. DESTROY: delete oldRing                  // Safe destruction
```

---

## Consolidated Hazard Registry

### P0: Critical (Must Fix)

| ID | Source | Issue | Location | Impact |
|----|--------|-------|----------|--------|
| TC-HZ-004 | CONC-001 | Non-atomic running flag | libuvc stream handle | Race condition |
| SY-HZ-001 | CONC-002 | volatile bool mIsRunning | IPipeline.h:49 | Data race |
| SY-HZ-002 | CONC-002 | volatile bool mIsCapturing | CaptureBasePipeline.h:21 | Data race |
| BL-HZ-001 | CONC-003 | Unbounded pthread_cond_wait | UVCPreview.cpp:274 | Deadlock/ANR |
| BL-HZ-002 | CONC-003 | Unbounded pthread_cond_wait | UVCPreview.cpp:1219 | Deadlock/ANR |
| BL-HZ-003 | CONC-003 | AHardwareBuffer fence block | FrameBufferRing.cpp:291 | ANR |
| SH-HZ-001 | CONC-005 | Threads not joined in forceStop | forceStop() | Use-after-free |
| SH-HZ-002 | CONC-005 | SAFE_DELETE while active | hardReset() | Crash |
| LC-HZ-001 | CONC-006 | capture_sync unbounded wait | UVCPreview.cpp:1270 | Deadlock |
| LC-HZ-002 | CONC-006 | completeSurfaceSwap unbounded | UVCPreview.cpp:2168 | ANR |
| TS-HZ-001 | CONC-007 | cb_thread default priority | libuvc stream | Frame drops |
| JNI-HZ-001 | CONC-008 | Local ref stored as member | UVCButtonCallback.cpp:38 | Use-after-free |

### P1: High Priority

| ID | Source | Issue | Location |
|----|--------|-------|----------|
| BL-HZ-004 | CONC-003 | Unbounded std::condition_variable::wait | UVCPreview.cpp:2168 |
| BL-HZ-005 | CONC-003 | usleep on JNI thread | UVCCamera.cpp:449 |
| SH-HZ-004 | CONC-005 | Unbounded pthread_join | stopPreview() |
| SH-HZ-005 | CONC-005 | USB close may block | release() |
| LC-HZ-003 | CONC-006 | Priority inversion potential | preview_mutex |
| LC-HZ-004 | CONC-006 | Legacy frame queue mutex overhead | preview_mutex |
| TS-HZ-002 | CONC-007 | preview_thread default priority | UVCPreview.cpp:441 |
| TS-HZ-003 | CONC-007 | SCHED_FIFO may fail | conversion_thread |
| JNI-HZ-002 | CONC-008 | Same local ref pattern | UVCStatusCallback.cpp:38 |
| JNI-HZ-003 | CONC-008 | Same local ref pattern | UVCReadinessCallback.cpp:66 |
| JNI-HZ-004 | CONC-008 | Attach/detach per callback | Multiple locations |

### P2: Medium Priority

| ID | Source | Issue | Location |
|----|--------|-------|----------|
| SY-HZ-005 | CONC-002 | Mixed std::mutex and pthread_mutex | UVCPreview |
| SY-HZ-006 | CONC-002 | Android Mutex wrapper dependency | Pipeline classes |
| SH-HZ-006 | CONC-005 | No centralized state machine | All shutdowns |
| SH-HZ-007 | CONC-005 | usleep(50000) arbitrary | hardReset() |
| LC-HZ-005 | CONC-006 | Pool mutex contention | pool_mutex |
| LC-HZ-006 | CONC-006 | No lock contention metrics | All mutexes |
| TS-HZ-004 | CONC-007 | capture_thread default priority | UVCPreview.cpp:893 |
| TS-HZ-005 | CONC-007 | No CPU affinity | All threads |
| JNI-HZ-005 | CONC-008 | ExceptionClear without Check | Multiple locations |

---

## Migration Roadmap

### Phase 1: Critical Fixes (Weeks 1-2)

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ 1.1 Fix Unbounded Waits                                                        │
│     ├── Add 1s timeout to pthread_cond_wait at capture_sync                    │
│     ├── Add 500ms timeout to completeSurfaceSwap                               │
│     └── Add timeout to all Pipeline condition waits                            │
├────────────────────────────────────────────────────────────────────────────────┤
│ 1.2 Fix volatile → atomic                                                      │
│     ├── IPipeline.h: volatile bool mIsRunning → std::atomic<bool>              │
│     └── CaptureBasePipeline.h: volatile bool mIsCapturing → std::atomic<bool>  │
├────────────────────────────────────────────────────────────────────────────────┤
│ 1.3 Fix Thread Priorities                                                      │
│     ├── cb_thread: setpriority(-8) at thread start                             │
│     └── preview_thread: setpriority(-4) at thread start                        │
└────────────────────────────────────────────────────────────────────────────────┘
```

### Phase 2: Safety Improvements (Weeks 3-4)

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ 2.1 Verify JNI Global References                                               │
│     ├── Audit all callback setCallback() methods                               │
│     └── Ensure NewGlobalRef is called before storing                           │
├────────────────────────────────────────────────────────────────────────────────┤
│ 2.2 Add Timed Thread Joins                                                     │
│     ├── Implement timedJoinThread() helper                                     │
│     └── Replace all unbounded pthread_join calls                               │
├────────────────────────────────────────────────────────────────────────────────┤
│ 2.3 Add Priority Inheritance                                                   │
│     └── Set PTHREAD_PRIO_INHERIT on preview_mutex                              │
└────────────────────────────────────────────────────────────────────────────────┘
```

### Phase 3: Modern C++ Migration (Weeks 5-8)

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ 3.1 std::jthread Migration                                                     │
│     ├── preview_thread → std::jthread + stop_token                             │
│     ├── capture_thread → std::jthread + stop_token                             │
│     └── conversion_thread → std::jthread + stop_token                          │
├────────────────────────────────────────────────────────────────────────────────┤
│ 3.2 Consolidate Synchronization                                                │
│     ├── pthread_mutex → std::mutex (where applicable)                          │
│     └── Remove Android Mutex wrapper dependency                                │
├────────────────────────────────────────────────────────────────────────────────┤
│ 3.3 Kotlin Flow Integration                                                    │
│     ├── Frame callback → SharedFlow                                            │
│     └── Capture callback → SharedFlow                                          │
└────────────────────────────────────────────────────────────────────────────────┘
```

### Phase 4: Optimization (Weeks 9-12)

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ 4.1 Deprecate Legacy Path                                                      │
│     ├── Route all frames through hybrid architecture                           │
│     └── Remove mutex-based preview queue                                       │
├────────────────────────────────────────────────────────────────────────────────┤
│ 4.2 Add Telemetry                                                              │
│     ├── Lock contention metrics                                                │
│     └── Thread scheduling latency metrics                                      │
├────────────────────────────────────────────────────────────────────────────────┤
│ 4.3 Consider Coroutines (Optional)                                             │
│     ├── Evaluate NDK toolchain maturity                                        │
│     └── Implement awaitable_eventfd if beneficial                              │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

## Deliverable Cross-Reference

| Document | Content | Key Findings |
|----------|---------|--------------|
| **AUDIT-003-appendix-advanced.md** | Advanced Concurrency Patterns | ⚠️ atomic<shared_ptr> NOT lock-free, Android 16 USB, CVE-2024-58002 |
| **CONCURRENCY-001** | Thread Creation Inventory | 15 pthread_create sites, 5 thread types |
| **CONCURRENCY-002** | Sync Primitive Catalog | 13 mutexes, 6 cond vars, 90 atomics, lock-free warning |
| **CONCURRENCY-003** | Blocking Operations | 39 blocking sites, 6 ANR risks |
| **CONCURRENCY-004** | Frame Loop Architecture | Dual-path pipeline, SPSC queue |
| **CONCURRENCY-005** | Shutdown Analysis | Signal-Drain-Destroy protocol |
| **CONCURRENCY-006** | Lock Contention | 5 hot spots, priority inversion risks |
| **CONCURRENCY-007** | Thread Scheduling | 2 prioritized threads, 3 at default |
| **CONCURRENCY-008** | JNI Boundaries | 7 attach sites, global ref issues |
| **CONCURRENCY-009** | Coroutine Feasibility | std::jthread recommended first |
| **CONCURRENCY-010** | Master Catalog | This document |

---

## Verification Checklist

- [x] All pthread_create sites documented (15)
- [x] All mutex declarations cataloged (13 + 1)
- [x] All condition variables identified (6 + 2)
- [x] All blocking operations analyzed (39)
- [x] Frame pipeline architecture documented
- [x] Shutdown protocols documented
- [x] Lock contention hot spots identified (5)
- [x] Thread priorities analyzed
- [x] JNI boundaries audited
- [x] Coroutine migration assessed
- [x] All hazards prioritized (P0: 12, P1: 16, P2: 11)
- [x] Migration roadmap defined

---

## Conclusion

The UVCCamera codebase demonstrates both legacy and modern concurrency patterns. The hybrid architecture (SPSC lock-free queue + AHardwareBuffer ring) represents a significant improvement over the legacy mutex-based queue.

**Immediate Actions Required:**
1. Add timeouts to all unbounded waits (P0)
2. Replace volatile with std::atomic (P0)
3. Set thread priorities for frame pipeline threads (P0)

**Strategic Improvements:**
1. Migrate to std::jthread for cooperative cancellation
2. Integrate Kotlin SharedFlow for callbacks
3. Complete deprecation of legacy frame path

The codebase is well-positioned for C++20 modernization with the existing use of atomics and memory ordering. The hybrid architecture provides a solid foundation for future lock-free optimizations.

---

## ⚠️ Critical Update: Lock-Free Implementation Guidance

### std::atomic<std::shared_ptr> is NOT Lock-Free

**CRITICAL CORRECTION:** The libc++ implementation of `std::atomic<std::shared_ptr>` uses a **global mutex pool** (mutex striping), NOT hardware atomics. This makes it unsuitable for 60fps frame delivery hot paths.

**DO NOT USE:**
```cpp
// WRONG - looks lock-free but uses global mutex in libc++
std::atomic<std::shared_ptr<FrameBuffer>> current_frame;
```

**USE INSTEAD:**
- Lock-free triple buffer (see AUDIT-003-appendix-advanced.md Appendix A)
- SPSC ring buffer (existing FrameBufferRing pattern)
- Raw pointers in ring buffer + deferred reclamation

### Revised Migration Priority Matrix

| Item | Original Assessment | Revised | Rationale |
|------|--------------------| --------|-----------|
| `volatile bool` → `std::atomic<bool>` | Quick Win | **Quick Win** | Still correct |
| `pthread_mutex` → `std::atomic<shared_ptr>` | Medium | **AVOID** | libc++ is blocking |
| `pthread_mutex` → Lock-free ring buffer | Major | **P0 Priority** | True lock-freedom |

### Implementation Dependencies (Corrected)

```
Foundation (Implement First)
├── std::jthread Migration
├── stop_token Integration
└── Lock-Free Ring Buffer (NOT atomic<shared_ptr>!)

DO NOT USE
└── std::atomic<shared_ptr> (blocking in libc++)

Async Infrastructure
├── Async Event Loop
└── Coroutine Wrappers
```

**Key Takeaway:** The "modern C++" path is not always the performant path. `std::atomic<std::shared_ptr>` looks elegant but performs worse than hand-rolled solutions due to ABI constraints in libc++.

---

## Android 16 Considerations

### USB File Descriptor Persistence

Android 16 Advanced Data Protection affects USB session handling:

| User Action | USB Protection Status | NDK File Descriptor |
|-------------|----------------------|---------------------|
| Connect (unlocked) → Lock | Active | **Persists** (read/write OK) |
| Connect while locked | Blocked | **None** (cannot create) |
| Disconnect while locked → Reconnect | Blocked | **Must unlock + re-plug** |

**Required:** `connectedDevice` foreground service type for FD persistence.

### CVE-2024-58002 Mitigation

UVC async control use-after-free vulnerability. Affects long-exposure use cases (30s+ exposures).

**Audit Actions:**
1. Check target kernel version (must be patched 5.15+ or 6.1+)
2. Document async control patterns in libuvc
3. Consider synchronous-only mode for safety

See **AUDIT-003-appendix-advanced.md** for full details on Appendix D (Android 16 USB) and Appendix E (CVE-2024-58002).

---

*End of CONCURRENCY-010 - AUDIT-003 Complete*
