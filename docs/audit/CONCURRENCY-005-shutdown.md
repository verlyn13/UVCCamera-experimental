# CONCURRENCY-005: Shutdown and Cancellation Path Analysis

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

This document analyzes the shutdown and cancellation paths in UVCCamera. Proper shutdown is critical for avoiding resource leaks, use-after-free bugs, and ANR during Activity/Fragment lifecycle transitions.

| Shutdown Type | Thread Join | Resource Cleanup | Risk Level |
|--------------|-------------|------------------|------------|
| **stopPreview()** | Yes (graceful) | Full | Low |
| **forceStop()** | No (skip join) | Partial | **High** |
| **release()** | Yes (cascaded) | Full | Medium |
| **hardReset()** | No (nuclear) | Full (force) | **High** |

---

## Shutdown Hierarchy

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           SHUTDOWN CALL HIERARCHY                               │
└─────────────────────────────────────────────────────────────────────────────────┘

    UVCCamera::release()
        │
        ├── stopPreview()
        │       │
        │       ├── mIsRunning.exchange(false)     // Signal threads
        │       ├── pthread_cond_signal()          // Wake waiters
        │       ├── clearRingBuffer()              // Signal-Drain-Destroy
        │       ├── stopConversionThread()         // Join conversion thread
        │       ├── pthread_join(capture_thread)   // Join capture
        │       └── pthread_join(preview_thread)   // Join preview
        │
        ├── mStatusCallback->release()
        ├── mButtonCallback->release()
        ├── mReadinessCallback->release()
        │
        ├── libusb_release_interface(0, 1)         // Release USB
        ├── uvc_close(mDeviceHandle)               // Close camera
        └── close(mFd)                             // Close file descriptor

    UVCCamera::hardReset()  (NUCLEAR OPTION)
        │
        ├── mPreview->forceStop()                  // Skip joins!
        ├── usleep(50000)                          // Hope threads notice
        ├── SAFE_DELETE(mStatusCallback)
        ├── SAFE_DELETE(mButtonCallback)
        ├── SAFE_DELETE(mPreview)                  // DELETE WITHOUT JOIN!
        ├── uvc_close()
        ├── libusb_reset_device()
        └── close(mFd)
```

---

## Graceful Shutdown: stopPreview()

### Thread Termination Sequence

```cpp
int UVCPreview::stopPreview() {
    // 1. Atomically set stop flag
    bool wasRunning = mIsRunning.exchange(false, std::memory_order_acq_rel);

    if (wasRunning) {
        // 2. Wake all waiting threads
        pthread_cond_signal(&preview_sync);
        pthread_cond_signal(&capture_sync);

        // 3. Clear ring buffer (Signal-Drain-Destroy)
        clearRingBuffer();

        // 4. Stop conversion thread
        stopConversionThread();

        // 5. Join capture thread (if valid)
        if (mCaptureThreadValid.exchange(false, std::memory_order_acq_rel)) {
            pthread_join(capture_thread, NULL);
            memset(&capture_thread, 0, sizeof(capture_thread));
        }

        // 6. Join preview thread (if valid)
        if (mPreviewThreadValid.exchange(false, std::memory_order_acq_rel)) {
            pthread_join(preview_thread, NULL);
            memset(&preview_thread, 0, sizeof(preview_thread));
        }

        // 7. Clear display resources
        clearDisplay();
    }

    // 8. Clear frame queues
    clearPreviewFrame();
    clearCaptureFrame();

    // 9. Release native windows
    // ... (mutex-protected)
}
```

### Thread Exit Points

| Thread | Exit Condition | Loop Construct | Notes |
|--------|---------------|----------------|-------|
| preview_thread | `!isRunning()` | `for (; isRunning();)` | Clean exit on flag |
| capture_thread | `!isRunning() \|\| !isCapturing()` | `for (; isRunning() && isCapturing();)` | Dual condition |
| conversion_thread | `!mConversionThreadRunning` | `while (mConversionThreadRunning)` | Separate flag |

---

## Signal-Drain-Destroy: clearRingBuffer()

The `clearRingBuffer()` function implements a sophisticated shutdown protocol to prevent use-after-free in USB callbacks.

### Protocol Steps

```
    ╔═══════════════════════════════════════════════════════════════════════╗
    ║              SIGNAL-DRAIN-DESTROY PROTOCOL                            ║
    ╚═══════════════════════════════════════════════════════════════════════╝

    STEP 0: SIGNAL
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ mUseRingBuffer.exchange(false)      // New callbacks exit immediately   │
    │ mRingBufferInjected.store(false)    // Double-check flag                │
    └─────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
    STEP 1: FENCE
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ std::atomic_thread_fence(seq_cst)   // Full barrier                     │
    └─────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
    STEP 2: DRAIN
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ while (mCallbacksInFlight > 0) {    // Wait for in-flight callbacks     │
    │     usleep(200);                    // 200μs polling                    │
    │     if (++retryCount > 500) break;  // 100ms timeout                    │
    │ }                                                                        │
    └─────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
    STEP 3: EXCHANGE
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ oldRing = mFrameBufferRing.exchange(nullptr)  // Atomically detach      │
    └─────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
    STEP 4: DESTROY
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ oldRing->poisonMagicHeaders()       // Aid debugging                    │
    │ delete oldRing;                      // Safe destruction                 │
    └─────────────────────────────────────────────────────────────────────────┘
```

### CallbackGuard RAII Pattern

```cpp
class CallbackGuard {
    std::atomic<int>& mCounter;
    bool mActive{false};
public:
    explicit CallbackGuard(std::atomic<int>& c) : mCounter(c), mActive(true) {
        mCounter.fetch_add(1, std::memory_order_acquire);
    }
    ~CallbackGuard() {
        if (mActive) {
            mCounter.fetch_sub(1, std::memory_order_release);
        }
    }
    void release() {
        if (mActive) {
            mCounter.fetch_sub(1, std::memory_order_release);
            mActive = false;
        }
    }
};

// Usage in USB callback
void uvc_preview_frame_callback(uvc_frame_t *frame, void *vptr_args) {
    CallbackGuard guard(preview->mCallbacksInFlight);  // Increment

    if (!preview->mUseRingBuffer.load(memory_order_acquire)) {
        return;  // Guard destructor decrements
    }

    // ... process frame ...
}  // Guard destructor decrements
```

---

## Force Shutdown: forceStop()

Used in `hardReset()` when graceful shutdown is impossible (e.g., USB disconnect with stuck threads).

```cpp
void UVCPreview::forceStop() {
    // Force stop WITHOUT joining threads
    mIsRunning.store(false, std::memory_order_release);
    mIsCapturing.store(false, std::memory_order_release);

    // Wake any blocked threads
    pthread_cond_broadcast(&preview_sync);
    pthread_cond_broadcast(&capture_sync);

    // Mark threads as invalid (skip join in destructor/stopPreview)
    mPreviewThreadValid.store(false, std::memory_order_release);
    mCaptureThreadValid.store(false, std::memory_order_release);
}
```

### Hazards

| ID | Issue | Risk | Mitigation |
|----|-------|------|------------|
| SH-HZ-001 | Threads not joined | **P0** - Thread may access deleted memory | Only use in hard reset scenarios |
| SH-HZ-002 | 50ms usleep arbitrary | **P1** - May not be enough | Add thread-safe acknowledgment |
| SH-HZ-003 | No memory fence after stop | **P2** - Store may not be visible | Add `atomic_thread_fence` |

---

## Hard Reset: hardReset()

Nuclear option for recovery from DeviceBusy errors.

```cpp
int UVCCamera::hardReset() {
    // 1. Force stop threads (no join!)
    if (mPreview) {
        mPreview->forceStop();
    }
    usleep(50000);  // Hope threads notice

    // 2. Delete helpers (may have active threads!)
    SAFE_DELETE(mStatusCallback);    // HAZARD: callback may be in progress
    SAFE_DELETE(mButtonCallback);    // HAZARD: callback may be in progress
    SAFE_DELETE(mReadinessCallback); // HAZARD: callback may be in progress
    SAFE_DELETE(mPreview);           // HAZARD: threads may still be running!

    // 3. Force close camera
    if (mDeviceHandle) {
        uvc_close(mDeviceHandle);    // May block if USB transfer in progress
        mDeviceHandle = NULL;
    }

    // 4. Reset USB device
    if (mDevice && mDevice->usb_dev) {
        libusb_device_handle *usb_devh = NULL;
        if (libusb_open(mDevice->usb_dev, &usb_devh) == 0) {
            libusb_reset_device(usb_devh);  // May block up to 5 seconds!
            libusb_close(usb_devh);
        }
    }

    // 5. Cleanup remaining resources
    // ...
}
```

### When to Use

- USB device physically disconnected
- Camera returns -EBUSY repeatedly
- Application is being force-killed
- Recovery from ANR

---

## Shutdown Hazards

### P0: Critical

| ID | Location | Issue | Impact | Fix |
|----|----------|-------|--------|-----|
| SH-HZ-001 | `forceStop()` | Threads not joined | Use-after-free | Track thread state, attempt timed join |
| SH-HZ-002 | `hardReset()` | SAFE_DELETE while active | Crash in callback | Add callback guards |
| SH-HZ-003 | `clearRingBuffer()` | 100ms timeout too short | Use-after-free | Increase timeout, add hard abort |

### P1: High

| ID | Location | Issue | Impact | Fix |
|----|----------|-------|--------|-----|
| SH-HZ-004 | `stopPreview()` | Unbounded pthread_join | ANR | Add timed join |
| SH-HZ-005 | `release()` | USB close may block | ANR | Add timeout wrapper |

### P2: Medium

| ID | Location | Issue | Impact | Fix |
|----|----------|-------|--------|-----|
| SH-HZ-006 | All shutdowns | No centralized state machine | Race conditions | Add State enum |
| SH-HZ-007 | `hardReset()` | usleep(50000) arbitrary | May not be enough | Use condition variable with timeout |

---

## Shutdown Order Requirements

### Correct Order (Current Implementation)

```
1. Signal threads to stop (mIsRunning = false)
2. Wake blocked threads (cond_signal)
3. Drain in-flight operations (clearRingBuffer)
4. Join threads (pthread_join)
5. Release USB interfaces
6. Close UVC device handle
7. Close file descriptor
```

### Order Violations to Avoid

| Violation | Consequence |
|-----------|-------------|
| Close FD before threads stop | SIGSEGV in USB read |
| Delete preview before thread join | Use-after-free |
| Release interface before stop streaming | LIBUSB_ERROR_IO |
| uvc_close before thread stop | Deadlock in libusb |

---

## Cancellation Patterns

### Pattern 1: Cooperative Cancellation (Current)

```cpp
// Thread loop
for (; isRunning();) {
    // ... do work ...
}
// Clean exit when isRunning() returns false
```

**Pros:** Clean, no forced termination
**Cons:** Thread must reach check point

### Pattern 2: C++20 std::stop_token (Recommended Migration)

```cpp
void preview_loop(std::stop_token token) {
    while (!token.stop_requested()) {
        // ... do work ...
    }
}

// Shutdown
mPreviewThread.request_stop();  // Non-blocking
mPreviewThread.join();          // Clean join
```

**Pros:** Standard, integrates with std::jthread
**Cons:** Requires C++20

### Pattern 3: pthread_cancel (Not Used - Good)

```cpp
// NOT USED - pthread_cancel is dangerous
// - May leave mutexes locked
// - May leak memory
// - Undefined behavior with C++ destructors
```

---

## Timeout Recommendations

| Operation | Current | Recommended | Rationale |
|-----------|---------|-------------|-----------|
| Callback drain | 100ms | 500ms | GC pauses can be >100ms |
| Thread join | Infinite | 2000ms | Avoid ANR |
| USB close | Infinite | 1000ms | Device may be unresponsive |
| libusb_reset | ~5000ms | Keep | Device may need reset time |

### Timed Join Implementation

```cpp
// pthread doesn't have timed join, use condition variable workaround
bool timedJoinThread(pthread_t thread, int timeoutMs) {
    std::atomic<bool> threadExited{false};

    // Wrapper that signals on exit
    auto wrapper = [&threadExited, thread]() {
        pthread_join(thread, NULL);
        threadExited.store(true);
    };

    std::thread joinThread(wrapper);
    joinThread.detach();

    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(timeoutMs);

    while (!threadExited.load() &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    return threadExited.load();
}
```

---

## Migration Strategy

### Phase 1: Add Timeouts to All Joins

```cpp
// Before
pthread_join(preview_thread, NULL);

// After
if (!timedJoinThread(preview_thread, 2000)) {
    LOGE("Preview thread join timeout - proceeding with destruction");
    // Thread may still be running - mark for tracking
}
```

### Phase 2: Migrate to std::jthread

```cpp
// Before
pthread_t preview_thread;
pthread_create(&preview_thread, NULL, preview_thread_func, this);

// After
std::jthread mPreviewThread;
mPreviewThread = std::jthread([this](std::stop_token token) {
    do_preview(token);
});
```

### Phase 3: Add State Machine

```cpp
enum class CameraState {
    DISCONNECTED,
    CONNECTED,
    PREVIEWING,
    STOPPING,
    RELEASING
};

std::atomic<CameraState> mState{CameraState::DISCONNECTED};

bool transitionTo(CameraState newState) {
    // Validate transition
    // Set new state
    // Notify waiters
}
```

---

## Cross-Reference

| Deliverable | Relationship |
|-------------|--------------|
| CONCURRENCY-001 | Threads being terminated |
| CONCURRENCY-002 | Atomics used in shutdown signaling |
| CONCURRENCY-003 | Blocking operations that must unblock |
| CONCURRENCY-004 | Frame loop exit conditions |
| SAFETY-007 | Hardware buffer cleanup |

---

*End of CONCURRENCY-005*
