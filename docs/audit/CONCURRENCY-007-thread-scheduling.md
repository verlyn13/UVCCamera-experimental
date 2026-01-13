# CONCURRENCY-007: Thread Scheduling and Priority Analysis

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

This document analyzes thread scheduling policies, priority assignments, and real-time constraints in the UVCCamera native codebase. Proper thread scheduling is critical for maintaining low-latency frame delivery without dropping frames.

| Thread | Scheduling Policy | Priority | Rationale |
|--------|------------------|----------|-----------|
| **conversion_thread** | SCHED_FIFO | max - 2 | Real-time frame conversion |
| **handler_thread** | nice(-18) | URGENT_AUDIO | USB event pump |
| **preview_thread** | SCHED_OTHER | Default (0) | **⚠️ No priority set** |
| **capture_thread** | SCHED_OTHER | Default (0) | **⚠️ No priority set** |
| **cb_thread** | SCHED_OTHER | Default (0) | **⚠️ No priority set** |

---

## Android Priority Definitions

From `localdefines.h`:

```cpp
#define THREAD_PRIORITY_DEFAULT           0
#define THREAD_PRIORITY_LOWEST           19
#define THREAD_PRIORITY_BACKGROUND       10
#define THREAD_PRIORITY_FOREGROUND       -2
#define THREAD_PRIORITY_DISPLAY          -4
#define THREAD_PRIORITY_URGENT_DISPLAY   -8
#define THREAD_PRIORITY_AUDIO           -16
#define THREAD_PRIORITY_URGENT_AUDIO    -19
```

**Nice Value Mapping:**
- `-19` = Highest priority (real-time audio)
- `0` = Default priority
- `+19` = Lowest priority (background)

---

## Thread Priority Analysis

### 1. Conversion Thread (SCHED_FIFO)

**Location:** `UVCPreview.cpp:2696-2701`

```cpp
// Set high priority for conversion thread (below USB callback, above render)
struct sched_param param;
param.sched_priority = sched_get_priority_max(SCHED_FIFO) - 2;
if (pthread_setschedparam(mConversionThread, SCHED_FIFO, &param) != 0) {
    LOGW("Failed to set conversion thread priority (non-fatal)");
}
```

| Attribute | Value |
|-----------|-------|
| **Policy** | SCHED_FIFO (real-time) |
| **Priority** | max - 2 (typically 97 on Linux) |
| **Rationale** | Minimize MJPEG→RGBX latency |
| **Risk** | May fail without CAP_SYS_NICE |

**SCHED_FIFO Characteristics:**
- Real-time scheduling (preempts SCHED_OTHER)
- No time slicing (runs until blocked or preempted by higher priority)
- Priority range: 1-99 on Linux, 1-127 on some Android

**Failure Mode:**
- Non-root processes typically cannot set SCHED_FIFO
- Falls back to default priority (warning logged)
- May cause frame drops under CPU pressure

---

### 2. Handler Thread (nice -18)

**Location:** `libuvc/src/init.c:98-105`

```cpp
#if defined(__ANDROID__)
    // try to increase thread priority
    int prio = getpriority(PRIO_PROCESS, 0);
    nice(-18);
    if (UNLIKELY(getpriority(PRIO_PROCESS, 0) >= prio)) {
        LOGW("could not change thread priority");
    }
#endif
```

| Attribute | Value |
|-----------|-------|
| **Policy** | SCHED_OTHER (default) |
| **Nice** | -18 (near URGENT_AUDIO) |
| **Rationale** | Prioritize USB event handling |
| **Platform** | Android-only optimization |

**Purpose:** The handler thread runs `libusb_handle_events()` in a loop. High priority ensures USB events are processed promptly, preventing transfer timeouts.

---

### 3. Preview Thread (No Priority Set)

**Location:** `UVCPreview.cpp:441`

```cpp
result = pthread_create(&preview_thread, NULL, preview_thread_func, (void *)this);
// No pthread_setschedparam call
```

| Attribute | Value |
|-----------|-------|
| **Policy** | SCHED_OTHER (inherited) |
| **Nice** | 0 (default) |
| **Issue** | Competes with other threads |

**Impact:** Preview thread performs Surface rendering which can block on SurfaceFlinger. Default priority may cause latency spikes when system is under load.

---

### 4. Capture Thread (No Priority Set)

**Location:** `UVCPreview.cpp:893`

```cpp
int createResult = pthread_create(&capture_thread, NULL, capture_thread_func, (void *)this);
// No pthread_setschedparam call
```

| Attribute | Value |
|-----------|-------|
| **Policy** | SCHED_OTHER (inherited) |
| **Nice** | 0 (default) |
| **Issue** | JPEG export may be slow |

---

### 5. Callback Thread (No Priority Set)

**Location:** `libuvc/src/stream.c:1630`

```cpp
pthread_create(&strmh->cb_thread, NULL, _uvc_user_caller, (void*) strmh);
// No priority setting
```

| Attribute | Value |
|-----------|-------|
| **Policy** | SCHED_OTHER (inherited) |
| **Nice** | 0 (default) |
| **Issue** | **P0 - USB callback latency** |

**Critical Issue:** The callback thread (`cb_thread`) dispatches USB frame data. If delayed, frames accumulate in the USB buffer and may be dropped. This is the most time-sensitive thread after the USB interrupt handler.

---

## Scheduling Hierarchy

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         THREAD PRIORITY HIERARCHY                               │
└─────────────────────────────────────────────────────────────────────────────────┘

    SCHED_FIFO (Real-time)
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Priority 99: [USB interrupt handler - kernel]
    Priority 97: conversion_thread (SCHED_FIFO max-2)
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    SCHED_OTHER (Time-shared)
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Nice -19: THREAD_PRIORITY_URGENT_AUDIO
    Nice -18: handler_thread (libusb events)
    Nice -16: THREAD_PRIORITY_AUDIO
    Nice -8:  THREAD_PRIORITY_URGENT_DISPLAY
    Nice -4:  THREAD_PRIORITY_DISPLAY
    Nice -2:  THREAD_PRIORITY_FOREGROUND
    ────────────────────────────────────────────────────────────────────────────
    Nice 0:   preview_thread, capture_thread, cb_thread  ← PROBLEM
    ────────────────────────────────────────────────────────────────────────────
    Nice 10:  THREAD_PRIORITY_BACKGROUND
    Nice 19:  THREAD_PRIORITY_LOWEST
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Priority Inversion Scenarios

### Scenario 1: cb_thread Blocked by Scheduler

```
┌──────────────────────────────────────────────────────────────────────┐
│  TIME ──────────────────────────────────────────────────────────────►│
├──────────────────────────────────────────────────────────────────────┤
│  USB IRQ:     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ (runs)       │
│  cb_thread:   ░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓▓▓░░░░░░ (delayed)        │
│  Other App:   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ (consuming)   │
├──────────────────────────────────────────────────────────────────────┤
│  Result: Frames queue up in USB buffer → overflow → drop             │
└──────────────────────────────────────────────────────────────────────┘
```

**Root Cause:** cb_thread has same priority as unrelated applications.

### Scenario 2: preview_thread Starved

```
┌──────────────────────────────────────────────────────────────────────┐
│  conversion_thread (RT):  ▓▓▓▓▓▓▓▓░░░▓▓▓▓▓▓▓▓░░░ (SCHED_FIFO)       │
│  preview_thread:          ░░░░░░░░░░░░░░░░░░░░░░░ (starved)         │
│  preview_sync:            ─────────────────────── (never waited)    │
├──────────────────────────────────────────────────────────────────────┤
│  Result: Frames converted but never rendered (ring buffer fills)    │
└──────────────────────────────────────────────────────────────────────┘
```

**Root Cause:** SCHED_FIFO preempts SCHED_OTHER indefinitely.

---

## Recommended Priority Assignments

### Priority Model

| Thread | Recommended Priority | Nice Value | Scheduling Policy |
|--------|---------------------|------------|-------------------|
| **cb_thread** | URGENT_DISPLAY | -8 | SCHED_OTHER |
| **conversion_thread** | RT (current) | N/A | SCHED_FIFO max-2 |
| **preview_thread** | DISPLAY | -4 | SCHED_OTHER |
| **capture_thread** | FOREGROUND | -2 | SCHED_OTHER |
| **handler_thread** | URGENT_AUDIO | -18 | SCHED_OTHER (current) |

### Implementation

#### cb_thread Priority (libuvc modification)

```cpp
// libuvc/src/stream.c - after pthread_create for cb_thread
#if defined(__ANDROID__)
static void *_uvc_user_caller(void *arg) {
    // Set priority at thread start
    setpriority(PRIO_PROCESS, 0, THREAD_PRIORITY_URGENT_DISPLAY);  // -8

    // ... existing code ...
}
#endif
```

#### preview_thread Priority

```cpp
// UVCPreview.cpp - after pthread_create for preview_thread
if (result == EXIT_SUCCESS) {
    mPreviewThreadValid.store(true, std::memory_order_release);
#if defined(__ANDROID__)
    // Set display priority for smooth rendering
    // Note: setpriority applies to calling thread when pid=0, tid=0
    // For other thread, use syscall(SYS_gettid) to get tid
    // Alternative: set priority inside the thread function
#endif
}
```

#### preview_thread_func Priority Setting

```cpp
static void *preview_thread_func(void *arg) {
#if defined(__ANDROID__)
    setpriority(PRIO_PROCESS, 0, THREAD_PRIORITY_DISPLAY);  // -4
#endif
    UVCPreview *preview = (UVCPreview *)arg;
    preview->do_preview();
    return NULL;
}
```

---

## Real-Time Constraints

### Frame Timing Budget (30 fps)

```
Frame interval: 33.33ms

┌─────────────────────────────────────────────────────────────────────────────────┐
│                         33.33ms FRAME BUDGET                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│ USB transfer:     │███████│                          (~3-5ms)                   │
│ cb_thread wake:   │       │█│                        (~0.5ms)                   │
│ Queue enqueue:    │        │█│                       (~0.1ms)                   │
│ MJPEG decode:     │         │██████│                 (~5-8ms)                   │
│ Color convert:    │               │███│              (~2-3ms)                   │
│ Surface lock:     │                   │██████████│   (~1-16ms)                  │
│ Blit + post:      │                             │███│(~2-3ms)                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│ Total minimum:    14.6ms                                                        │
│ Total maximum:    36.6ms (EXCEEDS BUDGET!)                                      │
│ Slack at best:    18.7ms                                                        │
│ Slack at worst:   -3.3ms (FRAME DROP)                                           │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Conclusion:** Surface lock variability (1-16ms) is the primary cause of frame drops.

### Critical Path Analysis

| Stage | Jitter Tolerance | Mitigation |
|-------|------------------|------------|
| USB transfer | Low (fixed timing) | None needed |
| cb_thread dispatch | **Critical** | Elevate priority to -8 |
| SPSC enqueue | High (lock-free) | Already optimized |
| MJPEG decode | Medium | SCHED_FIFO helps |
| Surface render | **High variance** | Use ring buffer (hybrid path) |

---

## CPU Affinity Considerations

### Current State

No CPU affinity (`sched_setaffinity`) is used. Threads may migrate between cores.

### Potential Optimization

```cpp
// Pin USB-critical threads to big cores on big.LITTLE systems
#include <sched.h>

void pin_to_big_cores(pthread_t thread) {
#if defined(__ANDROID__)
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    // Assume cores 4-7 are big cores (device-specific!)
    for (int i = 4; i < 8; i++) {
        CPU_SET(i, &cpuset);
    }
    pthread_setaffinity_np(thread, sizeof(cpuset), &cpuset);
#endif
}
```

**Caution:** Big.LITTLE core mapping varies by device. Use `android.os.Process.THREAD_PRIORITY_*` via JNI for portable priority management.

---

## Android-Specific Scheduling APIs

### setpriority vs pthread_setschedparam

| API | Scope | Android Support | Notes |
|-----|-------|-----------------|-------|
| `setpriority()` | Nice value | Full | Works for SCHED_OTHER |
| `pthread_setschedparam()` | RT policy | Limited | Requires CAP_SYS_NICE |
| `android_setThreadPriority()` | Android | Full | Wrapper around setpriority |

### Using Android SDK Priority (Preferred)

```cpp
#include <sys/resource.h>
#include <unistd.h>

// Set priority in native thread
void set_android_thread_priority(int priority) {
    setpriority(PRIO_PROCESS, gettid(), priority);
}
```

**Priority Constants (from `<android/os/Process.h>`):**
- `ANDROID_PRIORITY_URGENT_AUDIO = -19`
- `ANDROID_PRIORITY_AUDIO = -16`
- `ANDROID_PRIORITY_URGENT_DISPLAY = -8`
- `ANDROID_PRIORITY_DISPLAY = -4`
- `ANDROID_PRIORITY_FOREGROUND = -2`
- `ANDROID_PRIORITY_NORMAL = 0`
- `ANDROID_PRIORITY_BACKGROUND = 10`

---

## Hazard Summary

### P0: Critical

| ID | Thread | Issue | Impact | Fix |
|----|--------|-------|--------|-----|
| TS-HZ-001 | cb_thread | Default priority | Frame drops under load | `setpriority(-8)` |

### P1: High

| ID | Thread | Issue | Impact | Fix |
|----|--------|-------|--------|-----|
| TS-HZ-002 | preview_thread | Default priority | Render starvation | `setpriority(-4)` |
| TS-HZ-003 | conversion_thread | SCHED_FIFO may fail | No fallback strategy | Add setpriority fallback |

### P2: Medium

| ID | Thread | Issue | Impact | Fix |
|----|--------|-------|--------|-----|
| TS-HZ-004 | capture_thread | Default priority | JPEG export delays | `setpriority(-2)` |
| TS-HZ-005 | All threads | No CPU affinity | Core migration latency | Pin to big cores |

---

## Migration Strategy

### Phase 1: Add Priority to Critical Threads

1. **cb_thread:** Add `setpriority(PRIO_PROCESS, 0, -8)` at thread start
2. **preview_thread:** Add `setpriority(PRIO_PROCESS, 0, -4)` at thread start
3. **conversion_thread:** Add `setpriority` fallback when SCHED_FIFO fails

### Phase 2: Thread Naming (Debugging Aid)

```cpp
#include <pthread.h>

// Name threads for systrace/logcat
pthread_setname_np(preview_thread, "UVC:Preview");
pthread_setname_np(capture_thread, "UVC:Capture");
pthread_setname_np(mConversionThread, "UVC:Convert");
```

### Phase 3: Consider WorkerThread Wrapper

```cpp
class WorkerThread {
    pthread_t mThread;
    const char* mName;
    int mPriority;
    bool mRealtime;

public:
    WorkerThread(const char* name, int priority, bool realtime = false)
        : mName(name), mPriority(priority), mRealtime(realtime) {}

    template<typename F>
    int start(F&& func, void* arg) {
        // Create thread
        int result = pthread_create(&mThread, NULL, threadWrapper<F>, ...);
        if (result == 0) {
            // Set name
            pthread_setname_np(mThread, mName);
            // Set priority
            if (mRealtime) {
                struct sched_param param;
                param.sched_priority = sched_get_priority_max(SCHED_FIFO) - 2;
                if (pthread_setschedparam(mThread, SCHED_FIFO, &param) != 0) {
                    // Fallback to nice
                    setpriority(PRIO_PROCESS, /* get tid */, mPriority);
                }
            } else {
                setpriority(PRIO_PROCESS, /* get tid */, mPriority);
            }
        }
        return result;
    }
};
```

---

## Testing Recommendations

### Priority Verification

```bash
# Check thread priorities at runtime (requires adb shell)
adb shell cat /proc/<pid>/task/<tid>/stat
# Field 18 = priority, Field 19 = nice value

# Or use systrace for visual analysis
adb shell atrace --list_categories
adb shell atrace -c sched -b 32768 -t 5 > trace.html
```

### Load Testing

1. **CPU stress:** Run CPU-intensive background tasks
2. **Memory pressure:** Simulate low-memory conditions
3. **Multi-app:** Open multiple camera-using apps
4. **Thermal:** Test under thermal throttling

---

## Cross-Reference

| Deliverable | Relationship |
|-------------|--------------|
| CONCURRENCY-001 | Thread creation sites |
| CONCURRENCY-004 | Frame loop timing constraints |
| CONCURRENCY-006 | Lock contention affects scheduling |
| SAFETY-009 | pthread_create error checking |

---

*End of CONCURRENCY-007*
