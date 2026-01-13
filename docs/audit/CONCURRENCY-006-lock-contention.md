# CONCURRENCY-006: Lock Contention Hot Spots

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

This document identifies lock contention hot spots in the UVCCamera native codebase where multiple threads compete for the same mutex, potentially causing latency spikes or priority inversion.

| Mutex | Acquisitions | Contending Threads | Risk |
|-------|--------------|-------------------|------|
| `preview_mutex` | 12 | cb_thread, preview_thread, JNI | **High** |
| `capture_mutex` | 8 | preview_thread, capture_thread, JNI | **High** |
| `pool_mutex` | 4 | cb_thread, preview_thread | Medium |
| `mSwapMutex` | 4 | preview_thread, JNI | Medium |
| `mCaptureBufferMutex` | 4 | capture_thread, JNI | Low |

---

## Hot Spot #1: preview_mutex (Frame Queue)

### Contention Pattern

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         PREVIEW_MUTEX CONTENTION                                │
└─────────────────────────────────────────────────────────────────────────────────┘

    cb_thread (USB callback)          preview_thread
           │                                │
           │  addPreviewFrame()             │  waitPreviewFrame()
           ▼                                ▼
    ┌─────────────┐                  ┌─────────────┐
    │ LOCK        │◄─── CONTENDS ───►│ LOCK        │
    │ queue.put() │                  │ cond_wait() │
    │ UNLOCK      │                  │ queue.get() │
    └─────────────┘                  │ UNLOCK      │
                                     └─────────────┘
```

### Acquisition Sites

| Site | Thread | Operation | Duration |
|------|--------|-----------|----------|
| `UVCPreview.cpp:738` | cb_thread | `addPreviewFrame()` | < 1μs |
| `UVCPreview.cpp:755` | preview_thread | `waitPreviewFrame()` | 0-30ms (blocked) |
| `UVCPreview.cpp:778` | preview_thread | `clearPreviewFrame()` | Variable |
| `UVCPreview.cpp:439` | JNI (main) | `startPreview()` | < 1μs |
| `UVCPreview.cpp:508` | JNI (main) | `stopPreview()` | < 1μs |
| `UVCPreview.cpp:364` | preview_thread | `clearDisplay()` | < 1μs |
| `UVCPreview.cpp:837` | preview_thread | fps calculation | < 1μs |
| `UVCPreview.cpp:1188` | capture_thread | `copyToSurface()` | < 1μs |
| `UVCPreview.cpp:2116` | JNI (main) | `prepareForSurfaceSwap()` | < 1μs |
| `UVCPreview.cpp:2173` | JNI (main) | `completeSurfaceSwap()` | < 1μs |

### Contention Analysis

**Primary Contention:** cb_thread vs preview_thread

- **Frequency:** 30x/second (at 30fps)
- **cb_thread hold time:** < 1μs (just queue insert + signal)
- **preview_thread:** Holds lock while in `pthread_cond_timedwait` (up to 30ms)

**Impact:** Low - condition variable releases lock during wait

**Hazard:** If preview_thread is blocked elsewhere (e.g., Surface lock), cb_thread will block waiting for preview_mutex.

### Recommendation

The current implementation is reasonably efficient. The condition variable pattern releases the lock during the wait, minimizing contention.

For further optimization:
```cpp
// Consider lock-free SPSC queue (already implemented in hybrid path)
// Legacy path could be deprecated in favor of hybrid architecture
```

---

## Hot Spot #2: capture_mutex (Capture Queue)

### Contention Pattern

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         CAPTURE_MUTEX CONTENTION                                │
└─────────────────────────────────────────────────────────────────────────────────┘

    preview_thread                    capture_thread                JNI (main)
           │                                │                            │
           │ addCaptureFrame()              │ waitCaptureFrame()         │ setCaptureWindow()
           ▼                                ▼                            ▼
    ┌─────────────┐                  ┌─────────────┐              ┌─────────────┐
    │ LOCK        │◄────────────────►│ LOCK        │◄────────────►│ LOCK        │
    │ captureQueu=│                  │ cond_wait() │              │ release()   │
    │ UNLOCK      │                  │ frame=queu  │              │ UNLOCK      │
    └─────────────┘                  │ UNLOCK      │              └─────────────┘
                                     └─────────────┘
```

### Acquisition Sites

| Site | Thread | Operation | Duration |
|------|--------|-----------|----------|
| `UVCPreview.cpp:268` | JNI (main) | `setPreviewDisplay()` | < 1μs |
| `UVCPreview.cpp:348` | preview_thread | `clearDisplay()` | < 1μs |
| `UVCPreview.cpp:514` | JNI (main) | `stopPreview()` | < 1μs |
| `UVCPreview.cpp:1213` | preview_thread | `do_preview()` WARM→HOT | < 1μs |
| `UVCPreview.cpp:1250` | capture_thread | `addCaptureFrame()` | < 1μs |
| `UVCPreview.cpp:1267` | capture_thread | `waitCaptureFrame()` | 0-100ms |
| `UVCPreview.cpp:1285` | capture_thread | `clearCaptureFrame()` | Variable |
| `UVCPreview.cpp:1396` | capture_thread | frame export | Variable |

### Contention Analysis

**Primary Contention:** preview_thread vs capture_thread

- **Frequency:** On-demand (when capture enabled)
- **Hold times:** Generally short (< 1μs for queue ops)
- **Hazard:** `waitCaptureFrame()` unbounded wait (no timeout!)

### Hazard: Unbounded Wait

```cpp
// UVCPreview.cpp:1270 - NO TIMEOUT!
pthread_cond_wait(&capture_sync, &capture_mutex);
```

**Impact:** If capture thread is waiting and no frames arrive, thread blocks indefinitely.

**Recommendation:**
```cpp
// Add timeout like preview_mutex
struct timespec ts;
clock_gettime(CLOCK_MONOTONIC, &ts);
ts.tv_sec += 1;  // 1 second timeout
pthread_cond_timedwait(&capture_sync, &capture_mutex, &ts);
```

---

## Hot Spot #3: pool_mutex (Frame Pool)

### Contention Pattern

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          POOL_MUTEX CONTENTION                                  │
└─────────────────────────────────────────────────────────────────────────────────┘

    cb_thread (get)                   preview_thread (recycle)
           │                                │
           ▼                                ▼
    ┌─────────────┐                  ┌─────────────┐
    │ LOCK        │◄─── CONTENDS ───►│ LOCK        │
    │ pool.last() │                  │ pool.put()  │
    │ UNLOCK      │                  │ UNLOCK      │
    └─────────────┘                  └─────────────┘
```

### Acquisition Sites

| Site | Thread | Operation | Duration |
|------|--------|-----------|----------|
| `UVCPreview.cpp:153` | cb_thread | `get_frame()` | < 1μs |
| `UVCPreview.cpp:168` | Any | `recycle_frame()` | < 1μs |
| `UVCPreview.cpp:184` | JNI (main) | `init_pool()` | ~100μs |
| `UVCPreview.cpp:198` | JNI (main) | `clear_pool()` | ~100μs |

### Contention Analysis

**Primary Contention:** cb_thread vs preview_thread (via recycle)

- **Frequency:** 60x/second (get + recycle per frame at 30fps)
- **Hold times:** < 1μs each
- **Impact:** Low - very short critical sections

### Recommendation

Pool operations are already efficient. For zero-contention:
```cpp
// Use lock-free pool (hybrid path already uses SPSC queue which avoids this)
```

---

## Hot Spot #4: mSwapMutex (Surface Swap)

### Contention Pattern

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         SWAP_MUTEX CONTENTION                                   │
└─────────────────────────────────────────────────────────────────────────────────┘

    JNI (main)                        preview_thread
           │                                │
           │ prepareForSurfaceSwap()        │ checkSwapState()
           ▼                                ▼
    ┌─────────────┐                  ┌─────────────┐
    │ LOCK        │◄─── CONTENDS ───►│ LOCK        │
    │ setSwapping │                  │ cond_wait() │
    │ wait idle   │                  │ ...         │
    │ UNLOCK      │                  │ UNLOCK      │
    └─────────────┘                  └─────────────┘
```

### Acquisition Sites

| Site | Thread | Operation | Duration |
|------|--------|-----------|----------|
| `UVCPreview.cpp:929` | preview_thread | Frame loop swap check | 0-indefinite |
| `UVCPreview.cpp:1015` | preview_thread | Frame loop swap check | 0-indefinite |
| `UVCPreview.cpp:2100` | JNI (main) | `prepareForSurfaceSwap()` | 0-500ms |
| `UVCPreview.cpp:2162` | JNI (main) | `completeSurfaceSwap()` | 0-indefinite |

### Contention Analysis

**Handshake Protocol:**
1. JNI sets `mSwappingSurface = true`
2. JNI waits for `mIsRenderIdle` (render thread parked)
3. JNI performs swap
4. JNI sets `mSwappingSurface = false`
5. Preview thread resumes

**Hazard:** `completeSurfaceSwap()` has unbounded wait!

```cpp
// UVCPreview.cpp:2168 - NO TIMEOUT
mRenderThreadIdleCond.wait(lock, predicate);
```

**Impact:** If preview thread never becomes idle (e.g., stuck in ANativeWindow_lock), JNI thread blocks indefinitely → ANR.

### Recommendation

```cpp
// Already fixed in prepareForSurfaceSwap (500ms timeout)
// Apply same pattern to completeSurfaceSwap:
bool success = mRenderThreadIdleCond.wait_for(lock,
    std::chrono::milliseconds(500), predicate);
if (!success) {
    LOGW("Surface swap timeout - forcing completion");
}
```

---

## Hot Spot #5: mCaptureBufferMutex

### Acquisition Sites

| Site | Thread | Operation | Duration |
|------|--------|-----------|----------|
| `UVCPreview.cpp:2408` | capture_thread | Buffer allocation | Variable |
| `UVCPreview.cpp:2424` | capture_thread | Buffer realloc | Variable |
| `UVCPreview.cpp:2608` | capture_thread | Copy to buffer | 1-5ms |

### Contention Analysis

**Primary User:** capture_thread only (during callback export)

**No contention** - single thread acquires this mutex.

---

## Priority Inversion Scenarios

### Scenario 1: cb_thread Blocked by preview_thread

```
1. preview_thread holds preview_mutex (in ANativeWindow_lock wait)
2. cb_thread tries to acquire preview_mutex in addPreviewFrame()
3. cb_thread blocks
4. USB isochronous transfers may overflow
5. Frames dropped
```

**Probability:** Medium (Surface lock can take 1-16ms)

### Scenario 2: JNI Blocked by Worker Thread

```
1. preview_thread holds capture_mutex
2. JNI (main thread) tries to acquire in stopPreview()
3. Main thread blocks
4. If > 5 seconds → ANR
```

**Probability:** Low (worker thread hold times are short)

### Mitigation: Priority Inheritance

Android NDK supports `PTHREAD_PRIO_INHERIT`:

```cpp
pthread_mutexattr_t attr;
pthread_mutexattr_init(&attr);
pthread_mutexattr_setprotocol(&attr, PTHREAD_PRIO_INHERIT);
pthread_mutex_init(&preview_mutex, &attr);
```

**Note:** May add overhead. Profile before enabling.

---

## Lock-Free Alternatives (Hybrid Path)

The hybrid architecture uses lock-free patterns that eliminate these contention points:

| Legacy Pattern | Hybrid Replacement |
|---------------|-------------------|
| `preview_mutex` + queue | SPSC lock-free queue |
| `pool_mutex` + frame pool | Embedded in PendingFrame (reused) |
| `capture_mutex` + frame | Direct callback from conversion thread |

### SPSC Queue Performance

```
Producer: USB callback
Consumer: Conversion thread

No locks required:
- Producer writes to slot, sets ready flag (release)
- Consumer reads ready flag (acquire), reads slot

Memory ordering ensures correctness without mutex.
```

---

## Contention Metrics to Add

For runtime analysis, consider adding:

```cpp
struct LockMetrics {
    std::atomic<uint64_t> acquisitions{0};
    std::atomic<uint64_t> contentions{0};  // trylock failed
    std::atomic<uint64_t> totalWaitNs{0};

    void recordAcquisition(bool contended, uint64_t waitNs) {
        acquisitions++;
        if (contended) contentions++;
        totalWaitNs += waitNs;
    }
};

// Usage
auto start = clock_gettime_ns();
int result = pthread_mutex_trylock(&preview_mutex);
if (result == EBUSY) {
    metrics.contentions++;
    pthread_mutex_lock(&preview_mutex);
}
auto elapsed = clock_gettime_ns() - start;
metrics.recordAcquisition(result == EBUSY, elapsed);
```

---

## Hazard Summary

### P0: Critical

| ID | Location | Issue | Fix |
|----|----------|-------|-----|
| LC-HZ-001 | `capture_sync` wait | Unbounded wait | Add 1s timeout |
| LC-HZ-002 | `completeSurfaceSwap` | Unbounded wait | Add 500ms timeout |

### P1: High

| ID | Location | Issue | Fix |
|----|----------|-------|-----|
| LC-HZ-003 | `preview_mutex` | Priority inversion potential | PTHREAD_PRIO_INHERIT |
| LC-HZ-004 | Legacy frame queue | Mutex overhead at 30fps | Migrate to hybrid path |

### P2: Medium

| ID | Location | Issue | Fix |
|----|----------|-------|-----|
| LC-HZ-005 | Pool mutex | Contention on get/recycle | Lock-free pool |
| LC-HZ-006 | No metrics | Can't measure contention | Add lock metrics |

---

## Migration Priority

1. **Fix unbounded waits** (P0) - Add timeouts
2. **Deprecate legacy path** - Route all frames through hybrid architecture
3. **Add priority inheritance** - Prevent inversion
4. **Add metrics** - Enable profiling

---

## Cross-Reference

| Deliverable | Relationship |
|-------------|--------------|
| CONCURRENCY-002 | Mutex declarations |
| CONCURRENCY-003 | Blocking waits under locks |
| CONCURRENCY-004 | Frame loop lock patterns |
| CONCURRENCY-005 | Lock behavior during shutdown |

---

*End of CONCURRENCY-006*
