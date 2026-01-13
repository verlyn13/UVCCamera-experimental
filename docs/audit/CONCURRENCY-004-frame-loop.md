# CONCURRENCY-004: Frame Capture Loop Architecture

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

This document describes the frame capture loop architecture in UVCCamera, focusing on the threading model, data flow, and synchronization patterns.

The system implements two parallel architectures:
1. **Legacy Path:** Direct frame queue with ANativeWindow rendering
2. **Hybrid Path:** SPSC queue → Conversion thread → AHardwareBuffer ring

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            UVC CAMERA FRAME FLOW                                │
└─────────────────────────────────────────────────────────────────────────────────┘

                              USB LAYER (libuvc)
    ┌───────────────────────────────────────────────────────────────┐
    │  isochronous_callback()  ──────────►  _uvc_user_caller thread │
    │  (USB interrupt context)              (frame assembly)        │
    └────────────────────────────┬──────────────────────────────────┘
                                 │
                                 ▼
    ┌───────────────────────────────────────────────────────────────┐
    │              uvc_preview_frame_callback()                     │
    │              (libuvc callback thread - cb_thread)             │
    └────────────────────────────┬──────────────────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │   mUseRingBuffer?       │
                    └────────────┬────────────┘
                                 │
            ┌────────────────────┼────────────────────┐
            │ false              │                    │ true
            ▼                    │                    ▼
    ┌───────────────┐            │            ┌───────────────────┐
    │ LEGACY PATH   │            │            │ HYBRID PATH       │
    │               │            │            │                   │
    │ uvc_duplicate │            │            │ enqueuePending    │
    │ addPreviewFrame            │            │ Frame() SPSC      │
    └───────┬───────┘            │            └─────────┬─────────┘
            │                    │                      │
            ▼                    │                      ▼
    ┌───────────────┐            │            ┌───────────────────┐
    │ previewFrames │            │            │ SPSC Ring Queue   │
    │ (mutex queue) │            │            │ (lock-free)       │
    └───────┬───────┘            │            └─────────┬─────────┘
            │                    │                      │
            │ preview_sync       │                      │ eventfd signal
            │ (cond var)         │                      │
            ▼                    │                      ▼
    ┌───────────────┐            │            ┌───────────────────┐
    │ preview_thread│            │            │ conversion_thread │
    │               │            │            │                   │
    │ waitPreviewFrame           │            │ dequeuePending    │
    │ MJPEG→YUYV→RGBX            │            │ MJPEG→YUYV→RGBX   │
    └───────┬───────┘            │            └─────────┬─────────┘
            │                    │                      │
            │                    │                      │
            ▼                    │                      ▼
    ┌───────────────┐            │            ┌───────────────────┐
    │ ANativeWindow │            │            │ AHardwareBuffer   │
    │ _lock         │            │            │ lockWriteBuffer   │
    │ copyToSurface │            │            │ MAILBOX policy    │
    │ _unlockAndPost│            │            │ unlockWriteBuffer │
    └───────┬───────┘            │            └─────────┬─────────┘
            │                    │                      │
            │                    │     ┌───────────────┬┘
            │                    │     │               │
            ▼                    ▼     ▼               ▼
    ┌───────────────────────────────────────────────────────────────┐
    │                    SURFACE COMPOSITOR                         │
    │                    (SurfaceFlinger)                          │
    └───────────────────────────────────────────────────────────────┘

    ┌───────────────┐                         ┌───────────────────┐
    │ capture_thread│                         │ Java Callback     │
    │ (JPEG export) │◄────── BOTH PATHS ─────►│ (frame data)      │
    └───────────────┘                         └───────────────────┘
```

---

## Thread Inventory (Frame Pipeline)

| Thread | Purpose | Created In | Lifetime |
|--------|---------|------------|----------|
| **cb_thread** | libuvc callback dispatcher | `uvc_start_streaming` | Stream duration |
| **preview_thread** | Legacy frame processing | `startPreview()` | Preview duration |
| **capture_thread** | JPEG/callback export | `startPreview()` | Preview duration |
| **conversion_thread** | Hybrid MJPEG→RGBX | `startConversionThread()` | Preview duration |
| **handler_thread** | libuvc USB event pump | `uvc_start_handler_thread` | Context lifetime |

---

## Data Flow: Legacy Path

### 1. USB Callback → Frame Queue

```cpp
// libuvc cb_thread calls:
void UVCPreview::uvc_preview_frame_callback(uvc_frame_t *frame, void *vptr_args) {
    // 1. Fast validation
    if (!preview->isRunning() || !frame) return;

    // 2. Duplicate frame (USB buffer will be reused)
    uvc_frame_t *copy = preview->get_frame(frame->data_bytes);
    uvc_duplicate_frame(frame, copy);

    // 3. Add to queue (mutex-protected)
    preview->addPreviewFrame(copy);
}
```

### 2. Frame Queue → Preview Thread

```cpp
void UVCPreview::addPreviewFrame(uvc_frame_t *frame) {
    pthread_mutex_lock(&preview_mutex);
    if (isRunning() && previewFrames.size() < MAX_FRAME) {
        previewFrames.put(frame);
        pthread_cond_signal(&preview_sync);  // Wake preview thread
    }
    pthread_mutex_unlock(&preview_mutex);
}
```

### 3. Preview Thread → Surface

```cpp
// preview_thread_func → do_preview()
for (; isRunning();) {
    frame_mjpeg = waitPreviewFrame();  // Blocking wait with 30ms timeout

    // Decode MJPEG → YUYV
    frame = get_frame(frameBytes);
    uvc_mjpeg2yuyv(frame_mjpeg, frame);
    recycle_frame(frame_mjpeg);

    // Convert YUYV → RGBX
    uvc_any2rgbx(frame, &rgbx_frame);

    // Copy to surface
    copyToSurface(frame, &mPreviewWindow);
}
```

---

## Data Flow: Hybrid Path

### 1. USB Callback → SPSC Queue

```cpp
void UVCPreview::uvc_preview_frame_callback(uvc_frame_t *frame, void *vptr_args) {
    // RAII guard increments mCallbacksInFlight
    CallbackGuard guard(preview->mCallbacksInFlight);

    // Atomic load ring buffer
    FrameBufferRing* ring = preview->mFrameBufferRing.load(memory_order_acquire);

    // Enqueue to lock-free SPSC queue
    if (!ring->enqueuePendingFrame(frame->data, frame->data_bytes, ...)) {
        // Queue full - drop frame
        telemetry->framesDroppedQueueFull++;
    }

    // Signal conversion thread
    ring->signalConversionThread();
}
```

### 2. SPSC Queue → Conversion Thread

```cpp
void UVCPreview::do_conversion_loop() {
    while (mConversionThreadRunning.load(memory_order_acquire)) {
        // Dequeue from SPSC (lock-free)
        PendingFrame* pending = ring->dequeuePendingFrame();
        if (!pending) {
            ring->waitForSignal(100);  // 100ms timeout
            continue;
        }

        // Lock destination AHardwareBuffer
        uint8_t* destPtr = ring->lockWriteBuffer(&strideBytes);

        // Decode: MJPEG → YUYV → RGBX
        uvc_mjpeg2yuyv(&src_frame, &temp_yuyv);
        uvc_any2rgbx(&temp_yuyv, &dest_frame);

        // Release to consumer
        ring->unlockWriteBuffer();
    }
}
```

### 3. Ring Buffer → Surface

Java side acquires buffer via `FrameBufferRing.acquireReadBuffer()` and blits to `GLSurfaceView`.

---

## SPSC Queue (Lock-Free)

### Structure

```cpp
struct PendingFrame {
    void* data;                       // Raw USB data
    size_t dataBytes;
    uint32_t width, height;
    int frameFormat;
    uint64_t callbackTimestampNs;
    std::atomic<bool> ready{false};   // SPSC synchronization
};

class FrameBufferRing {
    // SPSC queue (cache-line padded)
    PendingFrame mPendingFrames[PENDING_QUEUE_SIZE];  // 8 slots
    char _paddingWrite[64];
    std::atomic<int> mPendingWriteIdx{0};
    char _paddingRead[64];
    std::atomic<int> mPendingReadIdx{0};
};
```

### Producer (USB Callback Thread)

```cpp
bool enqueuePendingFrame(...) {
    int writeIdx = mPendingWriteIdx.load(memory_order_relaxed);
    int nextIdx = (writeIdx + 1) % PENDING_QUEUE_SIZE;

    // Check if queue full (would collide with reader)
    if (nextIdx == mPendingReadIdx.load(memory_order_acquire)) {
        return false;  // Queue full, drop frame
    }

    // Write data
    slot.data = ...;
    slot.ready.store(true, memory_order_release);
    mPendingWriteIdx.store(nextIdx, memory_order_release);
    return true;
}
```

### Consumer (Conversion Thread)

```cpp
PendingFrame* dequeuePendingFrame() {
    int readIdx = mPendingReadIdx.load(memory_order_relaxed);

    // Check if queue empty
    if (readIdx == mPendingWriteIdx.load(memory_order_acquire)) {
        return nullptr;  // Queue empty
    }

    // Check slot ready
    if (!slot.ready.load(memory_order_acquire)) {
        return nullptr;  // Not ready yet
    }

    // Return frame
    frame->ready.store(false, memory_order_release);
    mPendingReadIdx.store((readIdx + 1) % SIZE, memory_order_release);
    return frame;
}
```

---

## Triple Buffer Ring (AHardwareBuffer)

### MAILBOX Policy

```
Slot 0  ──┐
          │
Slot 1  ──┼── Producer writes to NEXT available slot
          │   Consumer reads LATEST completed slot
Slot 2  ──┘   Frames dropped when producer outpaces consumer
```

### State Transitions

```
┌─────────────────────────────────────────────────────────────┐
│              SLOT STATE MACHINE (per slot)                  │
└─────────────────────────────────────────────────────────────┘

    EMPTY ─────lockWriteBuffer()────► WRITING
      ▲                                   │
      │                                   │
 releaseReadBuffer()              unlockWriteBuffer()
      │                                   │
      │                                   ▼
   READING ◄────acquireReadBuffer()──── READY
```

### Thread Safety

| Operation | Thread | Memory Order |
|-----------|--------|--------------|
| `mWriteIndex.store()` | Producer | release |
| `mWriteIndex.load()` | Consumer | acquire |
| `mLatestCompleted.store()` | Producer | release |
| `mLatestCompleted.load()` | Consumer | acquire |

---

## Frame Drop Policy

### Queue Full Drop (SPSC)

```cpp
// USB callback thread
if (!ring->enqueuePendingFrame(...)) {
    telemetry->framesDroppedQueueFull++;
    return;  // Drop frame, USB continues
}
```

### Mailbox Overwrite (Ring Buffer)

```cpp
// Conversion thread
// Writes to next slot regardless of consumer speed
// Consumer always gets LATEST frame (may skip intermediate)
```

### Queue Size Impact

| Queue Size | Latency | Resilience |
|------------|---------|------------|
| Small (4) | Low (~16ms) | May drop on GC pauses |
| Medium (8) | Medium (~32ms) | Balances latency/resilience |
| Large (16) | High (~64ms) | Survives long stalls |

---

## State Machine: PreviewState

```
    ┌─────────────────────────────────────────────────────────────┐
    │                    PREVIEW STATE MACHINE                    │
    └─────────────────────────────────────────────────────────────┘

                 startPreview() without surface
                           │
                           ▼
    ┌──────┐         ┌──────────┐         ┌──────┐
    │ COLD │────────►│   WARM   │────────►│ HOT  │
    └──────┘         └──────────┘         └──────┘
        │                 │ ▲                 │
        │                 │ │                 │
        │                 │ │                 │
        │                 ▼ │                 │
        │            (frames to              │
        │             ring buffer,           │
        │             no surface)            │
        │                                    │
        │                                    │
        │◄─────── stopPreview() ────────────►│
                                             │
                           setSurface(valid)─┘
                           setSurface(null)──►WARM
```

### State Behaviors

| State | USB Capture | Conversion | Surface Render | Capture Callback |
|-------|-------------|------------|----------------|------------------|
| COLD | No | No | No | No |
| WARM | Yes | Yes | No | Yes |
| HOT | Yes | Yes | Yes | Yes |

---

## Critical Sections

### 1. Frame Queue (Legacy)

```cpp
pthread_mutex_lock(&preview_mutex);
// previewFrames access
pthread_mutex_unlock(&preview_mutex);
```
**Duration:** < 1μs (queue operations only)

### 2. Surface Lock (Both Paths)

```cpp
ANativeWindow_lock(mPreviewWindow, &buffer, NULL);
// memcpy frame data
ANativeWindow_unlockAndPost(mPreviewWindow);
```
**Duration:** 1-16ms (depends on SurfaceFlinger)

### 3. AHardwareBuffer Lock (Hybrid)

```cpp
AHardwareBuffer_lock(buffer, usage, fenceFd, ...);
// memcpy conversion output
AHardwareBuffer_unlock(buffer, &fenceFd);
```
**Duration:** < 1ms (GPU fence already polled)

---

## Latency Budget

### Target: 30fps (33.3ms frame interval)

| Stage | Legacy | Hybrid | Budget |
|-------|--------|--------|--------|
| USB → Callback | 1ms | 1ms | 5ms |
| Queue wait | 5-30ms | 0-5ms | 10ms |
| MJPEG decode | 3-8ms | 3-8ms | 10ms |
| Color convert | 1-3ms | 1-3ms | 5ms |
| Surface lock | 1-16ms | 0ms* | 5ms |
| **Total** | **11-58ms** | **5-17ms** | **35ms** |

*Hybrid path defers surface lock to Java/GL layer

---

## Hazard Summary

### P0: Critical

| ID | Location | Issue | Impact |
|----|----------|-------|--------|
| FL-HZ-001 | `uvc_preview_frame_callback` | Frame duplication in USB callback | High latency |
| FL-HZ-002 | Legacy path | Unbounded queue growth | Memory exhaustion |

### P1: High

| ID | Location | Issue | Impact |
|----|----------|-------|--------|
| FL-HZ-003 | `waitPreviewFrame` | 30ms timeout during active streaming | Unnecessary waits |
| FL-HZ-004 | `addPreviewFrame` | Mutex contention on queue | Latency spikes |

### P2: Medium

| ID | Location | Issue | Impact |
|----|----------|-------|--------|
| FL-HZ-005 | Both paths | Double conversion (MJPEG→YUYV→RGBX) | CPU overhead |
| FL-HZ-006 | Legacy | Single consumer thread | No parallelism |

---

## Migration Strategy

### Phase 1: Deprecate Legacy Path

1. Make ring buffer the default
2. Add telemetry to legacy path
3. Monitor frame drop rates

### Phase 2: Direct MJPEG→RGBX

```cpp
// Replace two-step conversion:
// uvc_mjpeg2yuyv() → uvc_any2rgbx()
// With:
// turbojpeg_decompress_to_rgba() (single pass)
```

### Phase 3: Multi-Consumer Architecture

```cpp
// Current: Single conversion thread
// Future: Thread pool with work-stealing queue
class ConversionPool {
    std::vector<std::jthread> workers;
    moodycamel::ConcurrentQueue<PendingFrame> workQueue;
};
```

---

## Cross-Reference

| Deliverable | Relationship |
|-------------|--------------|
| **AUDIT-003-appendix-advanced.md** | Lock-free triple buffer (Appendix A), correct implementation pattern |
| CONCURRENCY-001 | Thread creation sites |
| CONCURRENCY-002 | Mutexes and atomics in frame path, atomic<shared_ptr> warning |
| CONCURRENCY-003 | Blocking operations (waitPreviewFrame) |
| CONCURRENCY-005 | Frame loop shutdown |
| CONCURRENCY-010 | Master catalog with updated hazards |
| SAFETY-007 | AHardwareBuffer fence handling |

### Lock-Free Implementation Note

⚠️ **CRITICAL:** When implementing lock-free frame buffers, do NOT use `std::atomic<std::shared_ptr>`. The libc++ implementation uses a global mutex pool (blocking). See `AUDIT-003-appendix-advanced.md` Appendix A for the correct lock-free triple buffer pattern with cache-line alignment.

---

*End of CONCURRENCY-004*
