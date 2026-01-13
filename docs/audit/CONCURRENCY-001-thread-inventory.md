# CONCURRENCY-001: Thread Creation Inventory

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

This document catalogs all thread creation sites in the UVCCamera native codebase. The analysis covers POSIX pthread creation, C++ std::thread usage, and thread function definitions.

| Category | Count |
|----------|-------|
| **pthread_create sites** | 15 |
| **std::thread usage** | 1 (test only) |
| **Thread entry points** | 16 |
| **pthread_join sites** | 21 |
| **pthread_exit sites** | 9 |
| **pthread_detach sites** | 0 |

---

## Thread Creation Sites by Component

### 1. UVCCamera Core (Application Layer)

| ID | File | Line | Thread Name | Purpose | Error Handling |
|----|------|------|-------------|---------|----------------|
| TC-001 | `UVCPreview.cpp` | 441 | `preview_thread` | Preview frame rendering | ✅ Checked |
| TC-002 | `UVCPreview.cpp` | 893 | `capture_thread` | Capture frame processing | ✅ Checked |
| TC-003 | `UVCPreview.cpp` | 2685 | `mConversionThread` | YUYV/MJPEG to RGBX conversion | ✅ Checked |

#### TC-001: Preview Thread
```cpp
// UVCPreview.cpp:441
result = pthread_create(&preview_thread, NULL, preview_thread_func, (void *)this);
if (result == EXIT_SUCCESS) {
    mPreviewThreadValid.store(true, std::memory_order_release);
}
```
- **Entry Point:** `preview_thread_func(void *vptr_args)`
- **Lifecycle:** Created in `startPreview()`, joined in `stopPreview()`
- **Shared State:** `mIsRunning`, `previewFrames`, `mPreviewWindow`, `mFrameBufferRing`
- **Stop Mechanism:** Atomic `mIsRunning` flag + condition variable signal
- **Hazards:** None identified (well-structured)

#### TC-002: Capture Thread
```cpp
// UVCPreview.cpp:893
int createResult = pthread_create(&capture_thread, NULL, capture_thread_func, (void *)this);
if (createResult == EXIT_SUCCESS) {
    mCaptureThreadValid.store(true, std::memory_order_release);
}
```
- **Entry Point:** `capture_thread_func(void *vptr_args)`
- **Lifecycle:** Created after `uvc_start_streaming_bandwidth()` succeeds, joined in `stopPreview()`
- **Shared State:** `mIsCapturing`, `captureQueu`, `mCaptureWindow`, `mFrameBufferRing`
- **Stop Mechanism:** Atomic `mIsCapturing` flag + condition variable
- **Hazards:** None identified

#### TC-003: Conversion Thread (Hybrid Architecture)
```cpp
// UVCPreview.cpp:2685
int result = pthread_create(&mConversionThread, NULL, conversion_thread_func, (void*)this);
```
- **Entry Point:** `conversion_thread_func(void *vptr_args)`
- **Lifecycle:** Created in `startConversionThread()`, joined in `stopConversionThread()`
- **Shared State:** `mConversionThreadRunning`, `mFrameBufferRing`, SPSC queue
- **Stop Mechanism:** Atomic flag + ring buffer signal
- **Priority:** `SCHED_FIFO` with `sched_get_priority_max(SCHED_FIFO) - 2`
- **Hazards:** None identified

---

### 2. Pipeline Layer

| ID | File | Line | Thread Name | Purpose | Error Handling |
|----|------|------|-------------|---------|----------------|
| TC-004 | `AbstractBufferedPipeline.cpp` | 66 | `handler_thread` | Frame buffer handler | ⚠️ Warning only |
| TC-005 | `SQLiteBufferedPipeline.cpp` | 131 | `handler_thread` | SQLite frame storage | ⚠️ Warning only |
| TC-006 | `CaptureBasePipeline.cpp` | 115 | `capture_thread` | Capture pipeline | ❌ Not checked |

#### TC-004: AbstractBufferedPipeline Handler Thread
```cpp
// AbstractBufferedPipeline.cpp:66
result = pthread_create(&handler_thread, NULL, handler_thread_func, (void *) this);
```
- **Entry Point:** `handler_thread_func(void *vptr_args)`
- **Lifecycle:** Created in `start()`, joined in `stop()`
- **Shared State:** `mIsRunning`, `frame_buffers`, `frame_pool`
- **Stop Mechanism:** `mIsRunning` flag + condition variable broadcast
- **Hazards:** `volatile bool mIsRunning` - not atomic (P1)

#### TC-005: SQLiteBufferedPipeline Handler Thread
```cpp
// SQLiteBufferedPipeline.cpp:131
result = pthread_create(&handler_thread, NULL, handler_thread_func, (void *) this);
```
- **Entry Point:** `handler_thread_func(void *vptr_args)`
- **Lifecycle:** Created in `start()`, joined in `stop()`
- **Stop Mechanism:** Same as AbstractBufferedPipeline
- **Hazards:** Same as TC-004

#### TC-006: CaptureBasePipeline Capture Thread
```cpp
// CaptureBasePipeline.cpp:115
pthread_create(&capture_thread, NULL, capture_thread_func, (void *)this);
```
- **Entry Point:** `capture_thread_func(void *vptr_args)`
- **Lifecycle:** Created in `startCapture()`, joined in `stopCapture()`
- **Hazards:** **P0** - No error checking on pthread_create return value

---

### 3. libuvc Layer

| ID | File | Line | Thread Name | Purpose | Error Handling |
|----|------|------|-------------|---------|----------------|
| TC-007 | `stream.c` | 1630 | `cb_thread` | User callback dispatcher | ❌ Not checked |
| TC-008 | `init.c` | 211 | `handler_thread` | USB event handler | ❌ Not checked |

#### TC-007: libuvc Callback Thread
```c
// libuvc/src/stream.c:1630
pthread_create(&strmh->cb_thread, NULL, _uvc_user_caller, (void*) strmh);
```
- **Entry Point:** `_uvc_user_caller(void *arg)`
- **Lifecycle:** Created in `uvc_start_streaming_bandwidth()`, joined in `uvc_stop_streaming()`
- **Shared State:** `strmh->running`, frame queue
- **Stop Mechanism:** `strmh->running = 0` (non-atomic!)
- **Hazards:** **P0** - Non-atomic stop flag, no error check

#### TC-008: libuvc Event Handler Thread
```c
// libuvc/src/init.c:211
pthread_create(&ctx->handler_thread, NULL, _uvc_handle_events, (void*) ctx);
```
- **Entry Point:** `_uvc_handle_events(void *arg)`
- **Lifecycle:** Created on first device open, joined on context destroy
- **Purpose:** Pumps libusb events for asynchronous USB operations
- **Hazards:** **P0** - No error check on thread creation

---

### 4. libusb Layer

| ID | File | Line | Thread Name | Purpose | Error Handling |
|----|------|------|-------------|---------|----------------|
| TC-009 | `android_netlink.c` | 155 | `libusb_android_event_thread` | Android hotplug events | ✅ Checked |
| TC-010 | `linux_netlink.c` | 139 | `libusb_linux_event_thread` | Linux hotplug events | ✅ Checked |
| TC-011 | `linux_udev.c` | 105 | `linux_event_thread` | udev hotplug events | ✅ Checked |
| TC-012 | `darwin_usb.c` | 432 | `libusb_darwin_at` | macOS USB events | ❌ Not checked |

#### TC-009: Android Netlink Event Thread
```c
// libusb/libusb/os/android_netlink.c:155
ret = pthread_create(&libusb_android_event_thread, NULL,
                     android_netlink_event_thread_main, NULL);
```
- **Entry Point:** `android_netlink_event_thread_main(void *arg)`
- **Lifecycle:** Module-scoped, started on init, stopped on exit
- **Purpose:** Monitors netlink socket for USB device attach/detach
- **Stop Mechanism:** `udev_monitor_fd` close triggers exit
- **Hazards:** None identified

---

### 5. Test Code

| ID | File | Line | Thread Name | Purpose |
|----|------|------|-------------|---------|
| TC-013 | `StreamTelemetryTest.cpp` | 47 | N/A | Test threading with std::thread |

```cpp
// test/tests/StreamTelemetryTest.cpp:47
std::vector<std::thread> threads;
```
- Only `std::thread` usage in codebase (test-only)
- Demonstrates modern threading could be adopted

---

## Thread Entry Point Summary

| Entry Point | File | Thread(s) | Loop Construct |
|------------|------|-----------|----------------|
| `preview_thread_func` | UVCPreview.cpp | preview_thread | `for (; isRunning();)` |
| `capture_thread_func` | UVCPreview.cpp | capture_thread | `for (; isRunning() && isCapturing();)` |
| `conversion_thread_func` | UVCPreview.cpp | mConversionThread | Wait on ring buffer signal |
| `handler_thread_func` | AbstractBufferedPipeline.cpp | handler_thread | `for (; isRunning();)` |
| `handler_thread_func` | SQLiteBufferedPipeline.cpp | handler_thread | `for (; isRunning();)` |
| `capture_thread_func` | CaptureBasePipeline.cpp | capture_thread | `for (; isRunning();)` |
| `_uvc_user_caller` | stream.c | cb_thread | `while (strmh->running)` |
| `_uvc_handle_events` | init.c | handler_thread | `while (!ctx->kill_handler_thread)` |
| `android_netlink_event_thread_main` | android_netlink.c | libusb_android_event_thread | `while (poll)` |
| `linux_netlink_event_thread_main` | linux_netlink.c | libusb_linux_event_thread | `while (poll)` |
| `linux_udev_event_thread_main` | linux_udev.c | linux_event_thread | `while (poll)` |
| `darwin_event_thread_main` | darwin_usb.c | libusb_darwin_at | `CFRunLoopRun()` |

---

## pthread_t Member Variables

| Variable | File | Scope | Initialized |
|----------|------|-------|-------------|
| `preview_thread` | UVCPreview.h:144 | Instance | Zero-init in constructor |
| `capture_thread` | UVCPreview.h:154 | Instance | Zero-init in constructor |
| `mConversionThread` | UVCPreview.h:256 | Instance | Default |
| `handler_thread` | AbstractBufferedPipeline.h:38 | Instance | Not initialized |
| `capture_thread` | CaptureBasePipeline.h:24 | Instance | Not initialized |
| `handler_thread` | SQLiteBufferedPipeline.h:35 | Instance | Not initialized |
| `cb_thread` | libuvc_internal.h:276 | Stream | Not initialized |
| `handler_thread` | libuvc_internal.h:320 | Context | Not initialized |
| `libusb_android_event_thread` | android_netlink.c:73 | Static | Zero-init |
| `libusb_linux_event_thread` | linux_netlink.c:60 | Static | Zero-init |
| `linux_event_thread` | linux_udev.c:51 | Static | Zero-init |
| `libusb_darwin_at` | darwin_usb.c:61 | Static | Zero-init |

---

## Hazard Summary

### P0: Critical (Block Release)

| ID | Location | Issue | Migration |
|----|----------|-------|-----------|
| TC-HZ-001 | `CaptureBasePipeline.cpp:115` | pthread_create return not checked | Add error handling |
| TC-HZ-002 | `stream.c:1630` | pthread_create return not checked | Add error handling |
| TC-HZ-003 | `init.c:211` | pthread_create return not checked | Add error handling |
| TC-HZ-004 | `stream.c:1630` | Non-atomic `running` flag | Use `std::atomic<bool>` |

### P1: High (Fix Before Migration)

| ID | Location | Issue | Migration |
|----|----------|-------|-----------|
| TC-HZ-005 | `IPipeline.h:49` | `volatile bool mIsRunning` not atomic | `std::atomic<bool>` |
| TC-HZ-006 | Pipeline headers | `pthread_t` not initialized | Initialize to 0 |

### P2: Medium (Address During Migration)

| ID | Location | Issue | Migration |
|----|----------|-------|-----------|
| TC-HZ-007 | All pthread sites | No thread attributes set | Consider stack size, priority |
| TC-HZ-008 | libuvc | pthread_detach never used | Review if detach needed for any threads |

---

## Thread Lifecycle Patterns

### Pattern 1: Valid Flag Pattern (Modern - UVCPreview)
```cpp
// Good pattern: atomic valid flag guards pthread_join
std::atomic<bool> mPreviewThreadValid{false};

// Create
if (pthread_create(...) == EXIT_SUCCESS) {
    mPreviewThreadValid.store(true, std::memory_order_release);
}

// Shutdown
if (mPreviewThreadValid.exchange(false, std::memory_order_acq_rel)) {
    pthread_join(preview_thread, NULL);
    memset(&preview_thread, 0, sizeof(preview_thread));
}
```
**Used by:** UVCPreview (preview, capture, conversion threads)

### Pattern 2: Running Flag Pattern (Legacy)
```cpp
// Less safe: running flag only
mIsRunning = true;
pthread_create(&handler_thread, NULL, handler_thread_func, this);

// Shutdown
if (isRunning()) {
    mIsRunning = false;
    pthread_join(handler_thread, NULL);
}
```
**Used by:** Pipeline classes, libuvc

### Pattern 3: Static Thread Pattern (libusb)
```cpp
// Module-level static thread
static pthread_t linux_event_thread;

// Create on init
pthread_create(&linux_event_thread, NULL, thread_main, NULL);

// Join on exit
pthread_join(linux_event_thread, NULL);
```
**Used by:** libusb platform backends

---

## Migration Strategy: pthread → std::jthread (C++20)

### Phase 1: Infrastructure

Create thread wrapper:
```cpp
// ThreadHandle.h
#include <thread>
#include <stop_token>
#include <atomic>

class ThreadHandle {
public:
    template<typename F>
    bool start(F&& func) {
        if (mThread.joinable()) return false;
        mThread = std::jthread(std::forward<F>(func));
        return true;
    }

    void request_stop() {
        mThread.request_stop();
    }

    void join() {
        if (mThread.joinable()) {
            mThread.join();
        }
    }

    bool joinable() const { return mThread.joinable(); }
    std::stop_token get_stop_token() { return mThread.get_stop_token(); }

private:
    std::jthread mThread;
};
```

### Phase 2: UVCPreview Migration (Example)
```cpp
// Before
pthread_t preview_thread;
std::atomic<bool> mPreviewThreadValid{false};
std::atomic<bool> mIsRunning{false};

// After
ThreadHandle mPreviewThread;

// Start
mPreviewThread.start([this](std::stop_token token) {
    do_preview(token);
});

// Loop
void do_preview(std::stop_token token) {
    while (!token.stop_requested()) {
        // ...
    }
}

// Stop
mPreviewThread.request_stop();
mPreviewThread.join();
```

### Phase 3: libuvc Migration
libuvc uses C - migration requires either:
1. C wrapper around std::jthread (complex)
2. Keep pthread with improved patterns
3. Rewrite libuvc streaming in C++ (recommended)

---

## Verification

### Thread Count Validation
```bash
# pthread_create sites
grep -rc 'pthread_create' lib/src/main/jni/ --include="*.c" --include="*.cpp" | grep -v ":0" | wc -l
# Expected: ~10 files with pthread_create

# pthread_t variables
grep -rc 'pthread_t' lib/src/main/jni/ --include="*.h" | grep -v ":0" | wc -l
# Expected: ~12 files with pthread_t declarations
```

---

## Cross-Reference

| Deliverable | Relationship |
|-------------|--------------|
| CONCURRENCY-002 | Mutexes protecting shared state |
| CONCURRENCY-003 | Blocking operations in threads |
| CONCURRENCY-004 | Preview/capture thread architecture |
| CONCURRENCY-005 | Thread shutdown paths |
| SAFETY-004 | Resource handle lifecycle |

---

*End of CONCURRENCY-001*
