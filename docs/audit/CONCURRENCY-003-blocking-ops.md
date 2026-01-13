# CONCURRENCY-003: Blocking Operation Analysis

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

This document catalogs all blocking operations in the UVCCamera native codebase. Blocking operations are critical for understanding ANR (Application Not Responding) risk and thread starvation scenarios.

| Category | Count |
|----------|-------|
| **usleep/sleep calls** | 12 (UVCCamera code) |
| **pthread_cond_wait** | 4 |
| **pthread_cond_timedwait** | 1 |
| **std::condition_variable::wait** | 7 |
| **poll() calls** | 3 (FrameBufferRing) |
| **AHardwareBuffer_lock** | 3 |
| **ANativeWindow_lock** | 6 |
| **libusb_handle_events** | 3 (libuvc) |

---

## Blocking Call Inventory

### 1. Sleep Operations (usleep)

| ID | File | Line | Duration | Thread | Purpose | ANR Risk |
|----|------|------|----------|--------|---------|----------|
| BL-001 | `UVCPreview.cpp` | 1696 | Variable (retry) | Preview | Retry delay on lock failure | Low |
| BL-002 | `UVCPreview.cpp` | 2352 | 1ms | Capture | Wait for capture buffer | Low |
| BL-003 | `UVCCamera.cpp` | 449 | 50ms | Any | Allow threads to notice state | **Medium** |
| BL-004 | `HandleManager.h` | 303 | 1ms | Any | Spinlock backoff | Low |
| BL-005 | `FrameBufferRing.cpp` | 1018 | 1ms | Conversion | Poll fallback | Low |
| BL-006 | `PublisherPipeline.cpp` | 212 | Variable | Publisher | Retry interval | Low |
| BL-007 | `hotplug.c` | 139 | 10ms | libusb | Hotplug delay | Low |
| BL-008 | `linux_usbfs.c` | 205 | Variable | libusb | Kernel delay | Low |

#### BL-001 Detail: Retry Delay on Lock Failure
```cpp
// UVCPreview.cpp:1696
usleep(retryDelayUs);  // Exponential backoff on surface lock failure
```
- **Context:** Called when `ANativeWindow_lock` returns error
- **Maximum Duration:** Bounded by retry count
- **ANR Risk:** Low (not on main thread)

#### BL-003 Detail: State Change Wait (Higher Risk)
```cpp
// UVCCamera.cpp:449
usleep(50000);  // 50ms to allow threads to notice
```
- **Context:** Called during state transitions
- **ANR Risk:** Medium - if called on JNI thread during lifecycle callbacks
- **Recommendation:** Replace with proper synchronization

---

### 2. Condition Variable Waits (pthread)

| ID | File | Line | Mutex | Timeout | Purpose | Thread |
|----|------|------|-------|---------|---------|--------|
| BL-010 | `UVCPreview.cpp` | 274 | `capture_mutex` | None | Wait for capture finish | Preview |
| BL-011 | `UVCPreview.cpp` | 767 | `preview_mutex` | 30ms | Wait for frame | Preview |
| BL-012 | `UVCPreview.cpp` | 1219 | `capture_mutex` | None | Wait for capture finish | Capture |
| BL-013 | `UVCPreview.cpp` | 1270 | `capture_mutex` | None | Wait for frame | Capture |

#### BL-010 Detail: Capture Finish Wait (Unbounded!)
```cpp
// UVCPreview.cpp:274
pthread_cond_wait(&capture_sync, &capture_mutex);  // wait finishing capturing
```
- **HAZARD:** Unbounded wait with no timeout
- **Deadlock Risk:** High if capture thread never signals
- **Recommendation:** Add timeout, add watchdog

#### BL-011 Detail: Frame Wait with Timeout (Good Pattern)
```cpp
// UVCPreview.cpp:767
pthread_cond_timedwait(&preview_sync, &preview_mutex, &ts);  // 30ms timeout
```
- **Good Pattern:** Bounded wait with 30ms timeout
- **No deadlock risk:** Timeout ensures progress

---

### 3. Condition Variable Waits (std::condition_variable)

| ID | File | Line | Predicate | Timeout | Purpose |
|----|------|------|-----------|---------|---------|
| BL-020 | `UVCPreview.cpp` | 930 | `!mSwappingSurface` | None | Wait for swap complete |
| BL-021 | `UVCPreview.cpp` | 1016 | `!mSwappingSurface` | None | Wait for swap complete |
| BL-022 | `UVCPreview.cpp` | 2107 | Render idle | 500ms | Wait for render thread |
| BL-023 | `UVCPreview.cpp` | 2168 | Render idle | None | Wait for render thread |

#### BL-022 Detail: Bounded Wait (Good Pattern)
```cpp
// UVCPreview.cpp:2107
bool success = mRenderThreadIdleCond.wait_for(lock,
    std::chrono::milliseconds(500), [this]{
        return mIsRenderIdle.load(std::memory_order_acquire) || !isRunning();
    });
```
- **Good Pattern:** 500ms timeout with predicate
- **Safe:** Returns false on timeout, allows recovery

#### BL-023 Detail: Unbounded Wait (Hazard)
```cpp
// UVCPreview.cpp:2168
mRenderThreadIdleCond.wait(lock, [this]{
    return mIsRenderIdle.load(std::memory_order_acquire) || !isRunning();
});
```
- **HAZARD:** No timeout, potential indefinite block
- **Mitigation:** Predicate includes `!isRunning()` for graceful shutdown
- **Recommendation:** Add timeout for safety

---

### 4. Pipeline Condition Waits

| ID | File | Line | Condition | Purpose |
|----|------|------|-----------|---------|
| BL-030 | `PreviewPipeline.cpp` | 129 | `capture_sync` | Wait for capture |
| BL-031 | `CallbackPipeline.cpp` | 54 | `capture_sync` | Wait for capture |
| BL-032 | `CaptureBasePipeline.cpp` | 101 | `capture_sync` | Wait for frame |
| BL-033 | `AbstractBufferedPipeline.cpp` | 163 | `pool_sync` | Wait for pool frame |
| BL-034 | `AbstractBufferedPipeline.cpp` | 285 | `buffer_sync` | Wait for buffer |

**All Pipeline Waits:** Use Android's `Condition::wait()` wrapper (unbounded)

---

### 5. poll() Calls

| ID | File | Line | Timeout | Purpose |
|----|------|------|---------|---------|
| BL-040 | `FrameBufferRing.cpp` | 257 | 33ms | Sync fence wait |
| BL-041 | `FrameBufferRing.cpp` | 1027 | Variable | Event fd wait |
| BL-042 | `linux_netlink.c` | 341 | -1 (infinite) | Hotplug events |

#### BL-040 Detail: Fence Synchronization
```cpp
// FrameBufferRing.cpp:257
int waitResult = poll(&pfd, 1, 33);  // 33ms timeout (just over 1 frame @ 30fps)
```
- **Purpose:** Wait for GPU fence to signal buffer ready
- **Good Timeout:** 33ms aligns with frame interval
- **Hazard:** None (bounded)

#### BL-042 Detail: Infinite Poll (Background Thread Only)
```cpp
// linux_netlink.c:341
while (poll(fds, 2, -1) >= 0) {  // Infinite wait
```
- **Context:** Background hotplug monitoring thread
- **Safe:** Only runs on dedicated background thread
- **Exit:** Breaks on pipe close signal

---

### 6. Hardware Buffer Locks

| ID | File | Line | Buffer Type | Fence | ANR Risk |
|----|------|------|------------|-------|----------|
| BL-050 | `FrameBufferRing.cpp` | 291 | AHardwareBuffer | Yes | **High** |
| BL-051 | `FrameBufferRing.cpp` | 308 | AHardwareBuffer | Yes | **High** |
| BL-052 | `FrameBufferRing.cpp` | 508 | AHardwareBuffer | Yes | **High** |

#### BL-050 Detail: AHardwareBuffer Lock with Fence
```cpp
// FrameBufferRing.cpp:291
res = AHardwareBuffer_lockAndGetInfo(
    mBuffers[idx],
    AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN,
    fenceFd,  // GPU fence - blocks until GPU done
    nullptr, &data, &stride, nullptr);
```
- **Blocking Source:** GPU fence synchronization
- **ANR Risk:** High if GPU stalls or fence never signals
- **Mitigation:** Use poll() on fence fd with timeout before lock

---

### 7. ANativeWindow Locks

| ID | File | Line | Context | ANR Risk |
|----|------|------|---------|----------|
| BL-060 | `UVCPreview.cpp` | 351 | Capture window | Medium |
| BL-061 | `UVCPreview.cpp` | 367 | Preview window | **High** |
| BL-062 | `UVCPreview.cpp` | 1136 | General window | **High** |
| BL-063 | `PreviewPipeline.cpp` | 90 | Preview window | **High** |

#### BL-061 Detail: Preview Window Lock
```cpp
// UVCPreview.cpp:367
if (LIKELY(ANativeWindow_lock(mPreviewWindow, &buffer, NULL) == 0)) {
```
- **Blocking Source:** SurfaceFlinger synchronization
- **ANR Risk:** High if SurfaceFlinger is under pressure
- **Mitigation:** Surface validation before lock, retry with backoff

---

### 8. libusb Event Handling

| ID | File | Line | Context | Purpose |
|----|------|------|---------|---------|
| BL-070 | `libuvc/init.c` | 107 | Event thread | Handle USB events |

```cpp
// libuvc/src/init.c:107
libusb_handle_events(ctx->usb_ctx);  // Blocks until USB event
```
- **Context:** Dedicated handler thread in libuvc
- **Safe:** Runs on background thread only
- **Exit:** Returns when context destroyed

---

## ANR Risk Assessment

### High Risk (May Block UI Thread)

| ID | Operation | Thread | Duration | Mitigation |
|----|-----------|--------|----------|------------|
| BL-050/51/52 | AHardwareBuffer_lock | Conversion | Unbounded | Add fence timeout |
| BL-060/61/62/63 | ANativeWindow_lock | Preview/Capture | Unbounded | Pre-validate surface |

### Medium Risk (May Cascade)

| ID | Operation | Thread | Duration | Mitigation |
|----|-----------|--------|----------|------------|
| BL-003 | usleep(50000) | JNI thread | 50ms | Use condition variable |
| BL-010/12/13 | pthread_cond_wait | Preview/Capture | Unbounded | Add timeout |

### Low Risk (Background Threads)

| ID | Operation | Thread | Duration | Notes |
|----|-----------|--------|----------|-------|
| BL-001/02/04/05/06 | usleep (1-10ms) | Worker | Bounded | Short delays |
| BL-011 | pthread_cond_timedwait | Preview | 30ms | Already bounded |
| BL-022 | wait_for(500ms) | Preview | 500ms | Already bounded |
| BL-040/41 | poll() | Conversion | 33ms | Already bounded |
| BL-070 | libusb_handle_events | Event handler | N/A | Dedicated thread |

---

## Deadlock Scenarios

### Scenario 1: Capture Never Signals

```
Thread A (Preview): pthread_cond_wait(&capture_sync) // BL-010
Thread B (Capture): [crashed/stuck - never signals]
Result: Thread A blocked forever
```

**Mitigation:** Add timeout to all unbounded waits

### Scenario 2: Surface Swap Stall

```
Thread A (Render): mSwappingCond.wait() // BL-020
Thread B (Main):   [didn't complete swap - stuck in JNI]
Result: Render thread blocked
```

**Mitigation:** Already has `!isRunning()` predicate as escape hatch

### Scenario 3: GPU Fence Never Signals

```
Thread A (Conversion): AHardwareBuffer_lock(fence) // BL-050
GPU: [driver bug/stall - fence never signals]
Result: Conversion thread blocked forever
```

**Mitigation:** Pre-poll fence fd with timeout before lock

---

## Migration Strategy: Blocking → Non-Blocking

### Pattern 1: Replace Unbounded Wait with Timed Wait

```cpp
// Before (hazard)
pthread_cond_wait(&capture_sync, &capture_mutex);

// After (safe)
struct timespec ts;
clock_gettime(CLOCK_REALTIME, &ts);
ts.tv_sec += 1;  // 1 second timeout
int result = pthread_cond_timedwait(&capture_sync, &capture_mutex, &ts);
if (result == ETIMEDOUT) {
    LOGW("Capture sync timeout - forcing recovery");
    // Recovery logic
}
```

### Pattern 2: C++20 std::condition_variable::wait_for

```cpp
// Before (hazard)
mRenderThreadIdleCond.wait(lock, predicate);

// After (safe)
auto result = mRenderThreadIdleCond.wait_for(
    lock,
    std::chrono::seconds(1),
    predicate
);
if (!result) {
    LOGW("Render idle timeout - forcing recovery");
}
```

### Pattern 3: Fence Polling Before Lock

```cpp
// Before (hazard)
AHardwareBuffer_lock(buffer, usage, fenceFd, ...);

// After (safe)
if (fenceFd >= 0) {
    struct pollfd pfd = {fenceFd, POLLIN, 0};
    int pollResult = poll(&pfd, 1, 100);  // 100ms timeout
    if (pollResult <= 0) {
        LOGE("Fence timeout - skipping frame");
        return ERROR_FENCE_TIMEOUT;
    }
}
AHardwareBuffer_lock(buffer, usage, -1, ...);  // No fence (already signaled)
```

### Pattern 4: Replace usleep with Condition Wait

```cpp
// Before (bad)
usleep(50000);  // Hope threads notice

// After (good)
std::unique_lock<std::mutex> lock(mStateMutex);
mStateChangeCond.notify_all();  // Wake waiting threads
bool allAcknowledged = mAckCond.wait_for(lock,
    std::chrono::milliseconds(50),
    [this]{ return mAckCount >= mThreadCount; });
```

---

## Hazard Summary

### P0: Critical (ANR Risk)

| ID | Location | Issue | Migration |
|----|----------|-------|-----------|
| BL-HZ-001 | `UVCPreview.cpp:274` | Unbounded pthread_cond_wait | Add 1s timeout |
| BL-HZ-002 | `UVCPreview.cpp:1219` | Unbounded pthread_cond_wait | Add 1s timeout |
| BL-HZ-003 | `FrameBufferRing.cpp:291` | AHardwareBuffer fence block | Pre-poll fence |

### P1: High (Potential Stall)

| ID | Location | Issue | Migration |
|----|----------|-------|-----------|
| BL-HZ-004 | `UVCPreview.cpp:2168` | Unbounded wait | Add timeout |
| BL-HZ-005 | `UVCCamera.cpp:449` | usleep on JNI thread | Condition variable |
| BL-HZ-006 | Pipeline waits | All unbounded | Add timeouts |

---

## Recommended Timeout Constants

```cpp
// Recommended timeout values for UVCCamera
namespace Timeouts {
    constexpr auto FRAME_WAIT_MS = 100;         // Wait for next frame
    constexpr auto CAPTURE_SYNC_MS = 1000;      // Wait for capture completion
    constexpr auto RENDER_IDLE_MS = 500;        // Wait for render thread idle
    constexpr auto FENCE_WAIT_MS = 33;          // GPU fence (1 frame @ 30fps)
    constexpr auto SURFACE_LOCK_MS = 16;        // Surface lock (1 frame @ 60fps)
    constexpr auto SHUTDOWN_GRACE_MS = 2000;    // Graceful shutdown
}
```

---

## Cross-Reference

| Deliverable | Relationship |
|-------------|--------------|
| CONCURRENCY-002 | Mutexes associated with condition variables |
| CONCURRENCY-005 | Shutdown uses these blocking operations |
| CONCURRENCY-006 | Lock contention at blocking points |
| SAFETY-007 | Hardware buffer fence handling |

---

*End of CONCURRENCY-003*
