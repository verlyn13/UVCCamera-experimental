# CONCURRENCY-002: Synchronization Primitive Catalog

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

This document catalogs all synchronization primitives in the UVCCamera native codebase. The analysis covers POSIX mutexes, condition variables, C++ atomics, and custom wrapper classes.

| Category | Count |
|----------|-------|
| **pthread_mutex_t declarations** | 13 |
| **pthread_mutex operations** | 150 |
| **pthread_cond_t declarations** | 6 |
| **pthread_cond operations** | 37 |
| **std::mutex instances** | 1 |
| **std::condition_variable** | 2 |
| **std::atomic variables** | ~90 |
| **memory_order operations** | 399 |
| **Android Mutex (wrapper)** | 8 |
| **Android Condition (wrapper)** | 4 |
| **volatile bool (HAZARD)** | 2 |

---

## pthread Mutex Declarations

### UVCCamera Core

| ID | Variable | File | Line | Purpose | Init | Destroy |
|----|----------|------|------|---------|------|---------|
| MX-001 | `preview_mutex` | UVCPreview.h | 146 | Protect preview thread/window | ✅ | ✅ |
| MX-002 | `capture_mutex` | UVCPreview.h | 156 | Protect capture thread/window | ✅ | ✅ |
| MX-003 | `pool_mutex` | UVCPreview.h | 165 | Protect frame pool | ✅ | ✅ |
| MX-004 | `mWarmFrameMutex` | UVCPreview.h | 127 | Protect warm state frame | ✅ | ✅ |
| MX-005 | `mCaptureBufferMutex` | UVCPreview.h | 288 | Protect capture buffer | ✅ | ✅ |
| MX-006 | `button_mutex` | UVCButtonCallback.h | 19 | Protect button callback | ✅ | ✅ |
| MX-007 | `status_mutex` | UVCStatusCallback.h | 19 | Protect status callback | ✅ | ✅ |
| MX-008 | `readiness_mutex` | UVCReadinessCallback.h | 40 | Protect readiness state | ✅ | ✅ |

### libuvc

| ID | Variable | File | Line | Purpose | Init | Destroy |
|----|----------|------|------|---------|------|---------|
| MX-009 | `cb_mutex` | libuvc_internal.h | 274 | Protect callback queue | ✅ | ✅ |
| MX-010 | `status_mutex` | libuvc_internal.h | 297 | Protect device status | ✅ | ✅ |

### libusb

| ID | Variable | File | Line | Purpose | Init | Destroy |
|----|----------|------|------|---------|------|---------|
| MX-011 | `libusb_darwin_at_mutex` | darwin_usb.c | 46 | Darwin thread sync | Static | N/A |
| MX-012 | `exit_cond_lock` | dpfp_threaded.c | 71 | Example exit sync | Static | N/A |

---

## pthread Condition Variable Declarations

| ID | Variable | File | Line | Associated Mutex | Purpose |
|----|----------|------|------|-----------------|---------|
| CV-001 | `preview_sync` | UVCPreview.h | 147 | `preview_mutex` | Preview frame availability |
| CV-002 | `capture_sync` | UVCPreview.h | 157 | `capture_mutex` | Capture frame availability |
| CV-003 | `cb_cond` | libuvc_internal.h | 275 | `cb_mutex` | Callback queue signal |
| CV-004 | `libusb_darwin_at_cond` | darwin_usb.c | 47 | `libusb_darwin_at_mutex` | Darwin event |
| CV-005 | `exit_cond` | dpfp_threaded.c | 70 | `exit_cond_lock` | Example exit signal |

---

## std::mutex and std::condition_variable

### Modern C++ Synchronization (UVCPreview)

| ID | Variable | File | Line | Purpose |
|----|----------|------|------|---------|
| SM-001 | `mSwapMutex` | UVCPreview.h | 130 | Surface swap coordination |
| SC-001 | `mRenderThreadIdleCond` | UVCPreview.h | 131 | Render thread idle signal |
| SC-002 | `mSwappingCond` | UVCPreview.h | 132 | Swap operation complete signal |

**Usage Pattern:**
```cpp
// Surface swap handshake
if (mSwappingSurface.load(std::memory_order_acquire)) {
    mIsRenderIdle.store(true, std::memory_order_release);
    mRenderThreadIdleCond.notify_one();

    std::unique_lock<std::mutex> lock(mSwapMutex);
    mSwappingCond.wait(lock, [this]{
        return !mSwappingSurface.load(std::memory_order_acquire);
    });
    mIsRenderIdle.store(false, std::memory_order_release);
}
```

---

## Android Mutex/Condition Wrappers (Legacy)

The pipeline classes use Android's `Mutex` and `Condition` wrapper classes from `namespace android`.

### Mutex Instances

| ID | Variable | File | Line | Scope |
|----|----------|------|------|-------|
| AM-001 | `pipeline_mutex` | IPipeline.h | 51 | Pipeline base |
| AM-002 | `pool_mutex` | AbstractBufferedPipeline.h | 34 | Frame pool |
| AM-003 | `buffer_mutex` | AbstractBufferedPipeline.h | 39 | Frame buffers |
| AM-004 | `handler_mutex` | SQLiteBufferedPipeline.h | 36 | Handler state |
| AM-005 | `capture_mutex` | CaptureBasePipeline.h | 22 | Capture state |
| AM-006 | `publisher_mutex` | PublisherPipeline.h | 28 | Publisher state |

### Condition Instances

| ID | Variable | File | Line | Associated Mutex |
|----|----------|------|------|-----------------|
| AC-001 | `pool_sync` | AbstractBufferedPipeline.h | 35 | `pool_mutex` |
| AC-002 | `buffer_sync` | AbstractBufferedPipeline.h | 40 | `buffer_mutex` |
| AC-003 | `handler_sync` | SQLiteBufferedPipeline.h | 37 | `handler_mutex` |
| AC-004 | `capture_sync` | CaptureBasePipeline.h | 23 | `capture_mutex` |

### Usage Pattern (Mutex::Autolock RAII)
```cpp
// Scoped lock pattern
Mutex::Autolock lock(capture_mutex);
// ... critical section ...
// Lock released at scope exit
```

---

## std::atomic Variables

### UVCPreview State Atomics

| ID | Variable | Type | Memory Order | Purpose |
|----|----------|------|--------------|---------|
| AT-001 | `mIsRunning` | `atomic<bool>` | acquire/release | Preview loop control |
| AT-002 | `mIsCapturing` | `atomic<bool>` | acquire/release | Capture loop control |
| AT-003 | `mSurfaceReady` | `atomic<bool>` | acquire/release | Surface availability |
| AT-004 | `mPreviewState` | `atomic<PreviewState>` | acquire/release | COLD/WARM/HOT state |
| AT-005 | `mSwappingSurface` | `atomic<bool>` | acquire/release | Swap in progress |
| AT-006 | `mIsRenderIdle` | `atomic<bool>` | acquire/release | Render thread parked |
| AT-007 | `mPreviewThreadValid` | `atomic<bool>` | release/acq_rel | Thread join guard |
| AT-008 | `mCaptureThreadValid` | `atomic<bool>` | release/acq_rel | Thread join guard |
| AT-009 | `mConversionThreadValid` | `atomic<bool>` | release/acq_rel | Thread join guard |
| AT-010 | `mConversionThreadRunning` | `atomic<bool>` | release | Conversion loop control |
| AT-011 | `mOutputMode` | `atomic<OutputMode>` | (default) | IDLE/SURFACE/RING/HYBRID |
| AT-012 | `mFrameBufferRing` | `atomic<FrameBufferRing*>` | acquire/release | Ring buffer pointer |
| AT-013 | `mUseRingBuffer` | `atomic<bool>` | acquire/release | Ring buffer enabled |
| AT-014 | `mRingBufferInjected` | `atomic<bool>` | acquire/release | External ownership |
| AT-015 | `mCallbacksInFlight` | `atomic<int>` | (default) | Active callback count |
| AT-016 | `mClearingRingBuffer` | `atomic<bool>` | (default) | Ring clear in progress |
| AT-017 | `sInstanceCounter` | `atomic<uint32_t>` | static | Debug instance tracking |
| AT-018 | `mCaptureCallbackEnabled` | `atomic<bool>` | (default) | Capture callback active |
| AT-019 | `mCaptureFormat` | `atomic<CapturePixelFormat>` | (default) | Pixel format |
| AT-020 | `mCaptureTargetFps` | `atomic<int>` | (default) | Target framerate |
| AT-021 | `mPreviewFps` | `atomic<int>` | release | Preview framerate |
| AT-022 | `mCaptureFrameCounter` | `atomic<uint64_t>` | (default) | Frame counter |
| AT-023 | `mCaptureCallbackInProgress` | `atomic<bool>` | release | Callback active |
| AT-024 | `mCaptureFramesEmitted` | `atomic<uint64_t>` | (default) | Telemetry |
| AT-025 | `mCaptureFramesDropped` | `atomic<uint64_t>` | (default) | Telemetry |
| AT-026 | `mCaptureCallbackBusy` | `atomic<uint64_t>` | (default) | Telemetry |
| AT-027 | `mDroppedNoSurface` | `atomic<uint64_t>` | (default) | Telemetry |
| AT-028 | `mDroppedQueueFull` | `atomic<uint64_t>` | (default) | Telemetry |
| AT-029 | `mTotalFramesProcessed` | `atomic<uint64_t>` | (default) | Telemetry |

### FrameBufferRing Atomics

| ID | Variable | Type | Memory Order | Purpose |
|----|----------|------|--------------|---------|
| AT-030 | `mWriteIndex` | `atomic<int>` | release | Producer index |
| AT-031 | `mReadIndex` | `atomic<int>` | acquire | Consumer index |
| AT-032 | `mLatestCompleted` | `atomic<int>` | acquire/release | Latest frame index |
| AT-033 | `mPendingWriteIdx` | `atomic<int>` | release | SPSC write index |
| AT-034 | `mPendingReadIdx` | `atomic<int>` | acquire/release | SPSC read index |
| AT-035 | `PendingFrame::ready` | `atomic<bool>` | acquire/release | Slot ready flag |

### HandleManager Atomics

| ID | Variable | Type | Purpose |
|----|----------|------|---------|
| AT-036 | `generation` | `atomic<uint32_t>` | Slot generation (even=dead, odd=alive) |
| AT-037 | `activeRefs` | `atomic<int>` | Reference count |
| AT-038 | `context` | `atomic<ContextPtr>` | Context pointer |
| AT-039 | `mNextFreeHint` | `atomic<uint32_t>` | Free slot search hint |

### StreamTelemetry Atomics (~50 variables)

Telemetry counters for diagnostics (USB stats, frame stats, latency, ring buffer state).

---

## Memory Ordering Patterns

### Pattern Analysis

| Pattern | Count | Example Location |
|---------|-------|------------------|
| `memory_order_acquire` | ~130 | Load operations |
| `memory_order_release` | ~120 | Store operations |
| `memory_order_acq_rel` | ~15 | exchange operations |
| `memory_order_seq_cst` | 1 | Thread fence |
| `memory_order_relaxed` | ~10 | Diagnostic loads |

### Acquire/Release Synchronization
```cpp
// Producer (write thread)
mFrameBufferRing.store(ring, std::memory_order_release);

// Consumer (read thread)
FrameBufferRing* ring = mFrameBufferRing.load(std::memory_order_acquire);
```

### Exchange Pattern for Thread Join Guards
```cpp
// Safe thread termination
bool wasRunning = mIsRunning.exchange(false, std::memory_order_acq_rel);
if (wasRunning) {
    // Signal and join
}

if (mPreviewThreadValid.exchange(false, std::memory_order_acq_rel)) {
    pthread_join(preview_thread, NULL);
}
```

---

## Hazards

### P0: Critical

| ID | Location | Issue | Impact | Migration |
|----|----------|-------|--------|-----------|
| SY-HZ-001 | `IPipeline.h:49` | `volatile bool mIsRunning` | Not atomic, data race | `std::atomic<bool>` |
| SY-HZ-002 | `CaptureBasePipeline.h:21` | `volatile bool mIsCapturing` | Not atomic, data race | `std::atomic<bool>` |

**Why volatile is wrong:**
```cpp
// WRONG: volatile does NOT provide atomicity or memory ordering
volatile bool mIsRunning;

// CORRECT: std::atomic provides both
std::atomic<bool> mIsRunning{false};
```

### P1: High

| ID | Location | Issue | Migration |
|----|----------|-------|-----------|
| SY-HZ-003 | libuvc | Non-atomic `running` flag in stream handle | `std::atomic<bool>` or mutex |
| SY-HZ-004 | Pipeline | Mixed pthread/Android wrapper patterns | Standardize on std::mutex |

### P2: Medium

| ID | Location | Issue | Migration |
|----|----------|-------|-----------|
| SY-HZ-005 | UVCPreview | Mixed std::mutex and pthread_mutex | Consolidate to std::mutex |
| SY-HZ-006 | Pipeline | Android Mutex wrapper (external dependency) | std::mutex |

---

## Lock Acquisition Order

### UVCPreview Lock Order (Must Acquire in This Order)

```
1. preview_mutex
   └── 2. capture_mutex
       └── 3. pool_mutex
           └── 4. mCaptureBufferMutex
               └── 5. mWarmFrameMutex
```

### Pipeline Lock Order

```
1. pipeline_mutex
   └── 2. buffer_mutex
       └── 3. pool_mutex
```

### Potential Deadlock Scenarios

| Scenario | Locks Involved | Risk | Mitigation |
|----------|---------------|------|------------|
| Preview/Capture conflict | preview_mutex + capture_mutex | Low | Always acquire in order |
| Ring buffer clear | mClearingRingBuffer + mCallbacksInFlight | Low | Atomic-based coordination |
| Surface swap | mSwapMutex + preview_mutex | Medium | Careful sequencing |

---

## Migration Strategy: POSIX → C++20

### Phase 1: Fix Hazards

Replace volatile with atomic:
```cpp
// Before (P0 hazard)
volatile bool mIsRunning;

// After
std::atomic<bool> mIsRunning{false};
```

### Phase 2: pthread_mutex → std::mutex

```cpp
// Before
pthread_mutex_t preview_mutex;
pthread_mutex_init(&preview_mutex, NULL);
pthread_mutex_lock(&preview_mutex);
// ... critical section ...
pthread_mutex_unlock(&preview_mutex);
pthread_mutex_destroy(&preview_mutex);

// After
std::mutex preview_mutex;
{
    std::lock_guard<std::mutex> lock(preview_mutex);
    // ... critical section ...
} // automatic unlock
```

### Phase 3: pthread_cond → std::condition_variable

```cpp
// Before
pthread_cond_t preview_sync;
pthread_mutex_t preview_mutex;
pthread_cond_init(&preview_sync, NULL);
pthread_cond_wait(&preview_sync, &preview_mutex);
pthread_cond_signal(&preview_sync);

// After
std::condition_variable preview_sync;
std::mutex preview_mutex;
std::unique_lock<std::mutex> lock(preview_mutex);
preview_sync.wait(lock, [this]{ return condition; });
preview_sync.notify_one();
```

### Phase 4: Remove Android Wrapper Dependency

Replace `android::Mutex` and `android::Condition` with std equivalents:
```cpp
// Before
Mutex::Autolock lock(buffer_mutex);

// After
std::lock_guard lock(buffer_mutex);
```

---

## Lock-Free Alternatives

### Current Lock-Free Patterns

1. **SPSC Queue (FrameBufferRing)**: Lock-free single-producer single-consumer queue for frame handoff
2. **Atomic Counters**: Telemetry without locks
3. **Generation-based Handle Manager**: Lock-free slot lookup with CAS

### ⚠️ CRITICAL WARNING: std::atomic<std::shared_ptr> is NOT Lock-Free

**Research Finding:** The libc++ implementation of `std::atomic<std::shared_ptr>` uses a **global mutex pool** (mutex striping), NOT hardware atomics.

**What Actually Happens:**
```cpp
// This looks lock-free but ISN'T in libc++
std::atomic<std::shared_ptr<FrameBuffer>> current_frame;

// Internal implementation:
// 1. Hash address of current_frame -> bucket index
// 2. Acquire global mutex from pool[bucket]
// 3. Perform non-atomic update
// 4. Release mutex
// If another shared_ptr hashes to same bucket -> BLOCKED
```

**Why libc++ Cannot Use True Lock-Free:**
- 128-bit atomics (LDXP/STXP) require 16-byte alignment
- `std::shared_ptr` is only 8-byte aligned
- Changing alignment would break ABI compatibility
- Google/LLVM prioritize ABI stability over performance

**DO NOT USE for frame delivery hot paths.** See `AUDIT-003-appendix-advanced.md` Appendix A for the correct lock-free triple buffer implementation.

### Recommended Additional Lock-Free Patterns

| Pattern | Use Case | C++20 Support |
|---------|----------|---------------|
| `std::atomic_ref` | Temporary atomic view | Yes |
| `std::latch` | One-time synchronization | Yes |
| `std::barrier` | Cyclic synchronization | Yes |
| `std::counting_semaphore` | Resource limiting | Yes |
| **Lock-Free Triple Buffer** | Frame delivery (60fps) | Custom (see Appendix A) |

### Correct Lock-Free Triple Buffer Pattern

```cpp
// TRUE lock-free triple buffer for frame delivery
class LockFreeFrameBuffer {
    alignas(64) std::array<FrameBuffer, 3> buffers_;  // Cache-line aligned
    alignas(64) std::atomic<uint32_t> write_idx_{0};  // Separate cache line
    alignas(64) std::atomic<uint32_t> read_idx_{1};   // Separate cache line

public:
    // Producer (capture thread) - wait-free, never blocks
    FrameBuffer& get_write_buffer() noexcept {
        return buffers_[write_idx_.load(std::memory_order_relaxed)];
    }

    void publish() noexcept {
        uint32_t current = write_idx_.load(std::memory_order_relaxed);
        uint32_t next = (current + 1) % 3;
        if (next == read_idx_.load(std::memory_order_acquire)) {
            next = (next + 1) % 3;  // Skip buffer being read
        }
        write_idx_.store(next, std::memory_order_release);
    }

    // Consumer (render/JNI thread) - wait-free, never blocks capture
    const FrameBuffer* get_read_buffer() noexcept {
        uint32_t latest = write_idx_.load(std::memory_order_acquire);
        uint32_t current = read_idx_.load(std::memory_order_relaxed);
        if (latest == current) return nullptr;  // No new frame
        read_idx_.store(latest, std::memory_order_release);
        return &buffers_[latest];
    }
};
```

### Performance Comparison

| Metric | libc++ atomic<shared_ptr> | Lock-Free Triple Buffer |
|--------|--------------------------|------------------------|
| Progress Guarantee | **Blocking** | **Wait-Free** |
| Latency Profile | High variance (mutex) | Deterministic |
| Cache Behavior | Thrashing (mutex + control block) | Optimized (padding) |
| Contention | Global (affects unrelated ptrs) | Local (producer/consumer only) |
| Reference Counting | Yes (RMW per access) | No (ownership by slot) |

---

## Cross-Reference

| Deliverable | Relationship |
|-------------|--------------|
| **AUDIT-003-appendix-advanced.md** | Lock-free triple buffer (Appendix A), Android 16 USB (D), CVE-2024-58002 (E) |
| CONCURRENCY-001 | Threads protected by these primitives |
| CONCURRENCY-003 | Blocking operations using cond vars |
| CONCURRENCY-004 | Frame loop architecture using lock-free buffers |
| CONCURRENCY-005 | Shutdown uses mutex + cond signal |
| CONCURRENCY-006 | Lock contention hot spots |
| CONCURRENCY-010 | Master catalog with updated hazards |
| SAFETY-009 | P0-008 (pthread_create error check) |

---

*End of CONCURRENCY-002*
