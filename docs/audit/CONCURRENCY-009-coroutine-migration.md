# CONCURRENCY-009: Coroutine Migration Feasibility

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

This document assesses the feasibility of migrating UVCCamera's threading model to coroutine-based architectures. Two migration paths are evaluated:

1. **C++20 Coroutines (Native):** For internal native threading
2. **Kotlin Coroutines (JNI Bridge):** For Java/Kotlin callback integration

| Migration Path | Feasibility | Complexity | Benefit |
|----------------|-------------|------------|---------|
| C++20 Coroutines | Medium | High | Non-blocking frame pipeline |
| Kotlin Coroutine Bridge | High | Medium | Structured callback handling |
| std::jthread (C++20) | High | Low | Cooperative cancellation |
| Lock-free (already used) | ✅ Complete | N/A | Zero contention frame path |

**Recommendation:** Prioritize `std::jthread` migration first (low risk, high benefit), defer full coroutine adoption until NDK toolchain matures.

---

## C++20 Coroutine Support

### NDK Toolchain Requirements

| Feature | NDK r28+ | Clang 17+ | Status |
|---------|----------|-----------|--------|
| `<coroutine>` header | ✅ | ✅ | Available |
| `co_await` / `co_yield` | ✅ | ✅ | Available |
| `std::generator` | ⚠️ | C++23 | Requires libstdc++ |
| `std::lazy` | ❌ | P2506 | Not standardized |

### Coroutine Executor Availability

```cpp
// Standard library (NDK r28+)
#include <coroutine>

// Third-party options
// - cppcoro (archived, but functional)
// - Boost.Asio coroutines
// - folly::coro (heavy dependency)
// - libunifex (P2300 reference impl)
```

**Android Limitation:** No standard coroutine executor in Android NDK. Must implement custom executor or use third-party library.

---

## Current Threading Model Analysis

### Thread Categories and Coroutine Suitability

| Thread | Purpose | Blocking Pattern | Coroutine Candidate |
|--------|---------|------------------|---------------------|
| **preview_thread** | Frame rendering | cond_wait + Surface lock | ⚠️ Medium |
| **capture_thread** | JPEG export | cond_wait + JNI callback | ✅ Good |
| **conversion_thread** | MJPEG decode | eventfd poll | ✅ Good |
| **cb_thread** | USB frame dispatch | cond_wait (libuvc) | ❌ Not recommended |
| **handler_thread** | libusb events | libusb_handle_events | ❌ Not recommended |

### Coroutine Candidate Analysis

#### Good Candidates (Async I/O Bound)

1. **conversion_thread:** Uses `poll()` on eventfd - perfect for `co_await`
2. **capture_thread:** Waits on queue then calls JNI - can be `async_generator`

#### Poor Candidates (External Library Constraints)

1. **cb_thread:** Owned by libuvc, callback-driven architecture
2. **handler_thread:** libusb internal event loop, cannot change

---

## Migration Path: std::jthread (Recommended First Step)

### Current Pattern

```cpp
// Current: Manual thread lifecycle
pthread_t preview_thread;
std::atomic<bool> mIsRunning{false};

void startPreview() {
    mIsRunning.store(true, std::memory_order_release);
    pthread_create(&preview_thread, NULL, preview_thread_func, this);
}

void stopPreview() {
    mIsRunning.store(false, std::memory_order_release);
    pthread_cond_signal(&preview_sync);
    pthread_join(preview_thread, NULL);
}

void* preview_thread_func(void* arg) {
    while (mIsRunning.load(std::memory_order_acquire)) {
        // ... work ...
    }
    return nullptr;
}
```

### Migrated Pattern (std::jthread)

```cpp
// Modern: std::jthread with stop_token
std::jthread mPreviewThread;

void startPreview() {
    mPreviewThread = std::jthread([this](std::stop_token stoken) {
        while (!stoken.stop_requested()) {
            // ... work ...
        }
    });
}

void stopPreview() {
    mPreviewThread.request_stop();  // Non-blocking
    // Destructor auto-joins
}
```

### Migration Complexity: LOW

| Aspect | Effort |
|--------|--------|
| Code changes | ~50 lines per thread |
| Testing | Existing tests work |
| Risk | Low (drop-in replacement) |
| Benefit | Auto-join, stop_token |

---

## Migration Path: C++20 Coroutines

### Frame Pipeline as Async Generator

```cpp
// Hypothetical: Frame stream as coroutine
#include <coroutine>
#include <generator>  // C++23 or cppcoro

std::generator<Frame> frameStream(std::stop_token stoken) {
    while (!stoken.stop_requested()) {
        // Wait for frame (non-blocking with executor)
        Frame frame = co_await pendingFrame();

        // Yield to consumer
        co_yield frame;
    }
}

// Consumer
for co_await (auto& frame : frameStream(stopToken)) {
    renderToSurface(frame);
}
```

### Required Infrastructure

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     COROUTINE INFRASTRUCTURE REQUIREMENTS                       │
└─────────────────────────────────────────────────────────────────────────────────┘

    1. EXECUTOR
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ - Thread pool for resumption                                            │
    │ - Integration with Android Looper (optional)                            │
    │ - Priority scheduling support                                           │
    └─────────────────────────────────────────────────────────────────────────┘

    2. AWAITABLE PRIMITIVES
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ - awaitable_eventfd (for SPSC signaling)                                │
    │ - awaitable_mutex (for resource protection)                             │
    │ - awaitable_timer (for timeout handling)                                │
    └─────────────────────────────────────────────────────────────────────────┘

    3. PROMISE TYPES
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ - task<T> (single value)                                                │
    │ - generator<T> (multiple values)                                        │
    │ - async_generator<T> (async multiple values)                            │
    └─────────────────────────────────────────────────────────────────────────┘
```

### Migration Complexity: HIGH

| Aspect | Effort |
|--------|--------|
| Executor implementation | 500-1000 lines |
| Awaitable primitives | 200-400 lines each |
| Code migration | Architectural change |
| Testing | New test patterns needed |
| Risk | High (new paradigm) |
| Benefit | Non-blocking pipeline |

---

## Migration Path: Kotlin Coroutine Bridge

### Current JNI Callback Pattern

```kotlin
// Kotlin side
interface IFrameCallback {
    fun onFrame(frame: ByteBuffer)
}

// Native callback (blocking)
void UVCPreview::invokeFrameCallback(JNIEnv* env, ...) {
    env->CallVoidMethod(mFrameCallbackObj, methodId, buffer);
}
```

### Coroutine Bridge Pattern

```kotlin
// Kotlin side - Flow-based
class UVCCamera {
    private val _frameFlow = MutableSharedFlow<Frame>(
        replay = 0,
        extraBufferCapacity = 3,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )

    val frameFlow: SharedFlow<Frame> = _frameFlow.asSharedFlow()

    // Native callback posts to flow
    private fun onNativeFrame(buffer: ByteBuffer, timestamp: Long) {
        _frameFlow.tryEmit(Frame(buffer, timestamp))
    }
}

// Consumer (non-blocking)
camera.frameFlow
    .buffer(3, BufferOverflow.DROP_OLDEST)
    .collect { frame ->
        renderFrame(frame)
    }
```

### Native Side Changes

```cpp
// Instead of blocking CallVoidMethod
void UVCPreview::invokeFrameCallback(JNIEnv* env, ...) {
    // Call Kotlin suspend function or emit to Channel
    // Option 1: tryEmit to MutableSharedFlow (non-blocking)
    jmethodID tryEmitMethod = env->GetMethodID(flowClass, "tryEmit", "(Ljava/lang/Object;)Z");
    env->CallBooleanMethod(mFrameFlowObj, tryEmitMethod, frameObj);

    // Option 2: Use Channel.trySend (non-blocking)
    // ...
}
```

### Migration Complexity: MEDIUM

| Aspect | Effort |
|--------|--------|
| Kotlin side | 100-200 lines |
| JNI changes | 50-100 lines |
| Testing | Flow testing patterns |
| Risk | Medium (well-understood) |
| Benefit | Structured concurrency |

---

## Blocking Operation Migration Difficulty

### Ranked by Migration Complexity

| Operation | Location | Current Pattern | Coroutine Target | Difficulty |
|-----------|----------|-----------------|------------------|------------|
| `pthread_cond_timedwait` | preview_sync | 30ms timeout | `co_await timer` | Medium |
| `poll(eventfd)` | FrameBufferRing | 100ms timeout | `co_await eventfd` | Low |
| `pthread_cond_wait` | capture_sync | Unbounded | `co_await + timeout` | Medium |
| `AHardwareBuffer_lock` | Ring buffer | GPU fence | Keep as-is | N/A |
| `ANativeWindow_lock` | Surface | SurfaceFlinger | Keep as-is | N/A |
| `libusb_handle_events` | handler_thread | Library internal | Not migratable | N/A |

### Migration Order (Recommended)

```
Phase 1: std::jthread Migration
├── preview_thread → std::jthread + stop_token
├── capture_thread → std::jthread + stop_token
└── conversion_thread → std::jthread + stop_token

Phase 2: Kotlin Flow Integration
├── Frame callback → SharedFlow
├── Capture callback → SharedFlow
└── Status callbacks → SharedFlow

Phase 3: C++20 Coroutines (Optional)
├── Implement awaitable_eventfd
├── conversion_thread → coroutine
└── Consider async_generator for frame pipeline
```

---

## Risk Assessment

### C++20 Coroutine Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| NDK toolchain bugs | Medium | High | Test on multiple NDK versions |
| No standard executor | High | Medium | Use cppcoro or custom |
| Debugging difficulty | High | Medium | Add coroutine tracing |
| Performance unknown | Medium | Low | Benchmark before adopting |
| Team learning curve | High | Medium | Incremental adoption |

### Kotlin Coroutine Bridge Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| JNI overhead | Low | Low | Already acceptable |
| Flow backpressure | Medium | Medium | Configure buffer policy |
| Exception propagation | Medium | Medium | Define error handling |

### std::jthread Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Minimal | Low | Low | Drop-in replacement |

---

## Compatibility Matrix

### NDK Version Requirements

| Feature | NDK r25 | NDK r26 | NDK r27 | NDK r28+ |
|---------|---------|---------|---------|----------|
| `<coroutine>` | ⚠️ | ⚠️ | ✅ | ✅ |
| `std::jthread` | ⚠️ | ✅ | ✅ | ✅ |
| `std::stop_token` | ⚠️ | ✅ | ✅ | ✅ |
| `std::atomic_wait` | ❌ | ⚠️ | ✅ | ✅ |
| `std::barrier` | ❌ | ⚠️ | ✅ | ✅ |
| `std::latch` | ❌ | ⚠️ | ✅ | ✅ |

**Target:** NDK r28+ for full C++20 support

### Kotlin Version Requirements

| Feature | Kotlin 1.6 | Kotlin 1.7 | Kotlin 1.8+ |
|---------|------------|------------|-------------|
| SharedFlow | ✅ | ✅ | ✅ |
| StateFlow | ✅ | ✅ | ✅ |
| Channel | ✅ | ✅ | ✅ |
| Flow.buffer | ✅ | ✅ | ✅ |

---

## Recommended Migration Timeline

### Short-Term (1-2 months)

1. **Migrate to std::jthread**
   - Replace pthread_create with std::jthread
   - Implement stop_token checking
   - Remove manual mIsRunning atomics

2. **Add Kotlin Flow for callbacks**
   - Frame callback → SharedFlow
   - Capture callback → SharedFlow

### Medium-Term (3-6 months)

3. **Implement awaitable primitives**
   - awaitable_eventfd for conversion thread
   - Test with cppcoro or custom executor

4. **Evaluate coroutine adoption**
   - Benchmark coroutine vs thread performance
   - Decision point for full coroutine migration

### Long-Term (6-12 months)

5. **Full coroutine pipeline (if beneficial)**
   - Async generator frame stream
   - Complete lock-free pipeline

---

## Code Examples

### Example 1: std::jthread with stop_callback

```cpp
#include <thread>
#include <stop_token>

class UVCPreview {
    std::jthread mConversionThread;

public:
    void startConversionThread() {
        mConversionThread = std::jthread([this](std::stop_token stoken) {
            // Register stop callback for immediate wakeup
            std::stop_callback callback(stoken, [this]() {
                mFrameBufferRing->signalConversionThread();
            });

            while (!stoken.stop_requested()) {
                if (!processNextFrame()) {
                    // Wait for signal or stop
                    mFrameBufferRing->waitForSignal(100);
                }
            }
        });
    }

    void stopConversionThread() {
        mConversionThread.request_stop();
        // Destructor handles join
    }
};
```

### Example 2: Awaitable eventfd (cppcoro-style)

```cpp
// Requires coroutine executor
#include <cppcoro/async_generator.hpp>
#include <cppcoro/static_thread_pool.hpp>

cppcoro::async_generator<Frame> frameStream(cppcoro::static_thread_pool& tp) {
    while (true) {
        // Non-blocking wait for frame
        co_await mFrameBufferRing->asyncWaitForFrame();

        // Dequeue frame
        auto* pending = mFrameBufferRing->dequeuePendingFrame();
        if (!pending) continue;

        // Process and yield
        Frame frame = processFrame(pending);
        co_yield frame;
    }
}
```

### Example 3: Kotlin SharedFlow integration

```kotlin
// In UVCCamera.kt
class UVCCamera {
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    private val _frameFlow = MutableSharedFlow<FrameData>(
        extraBufferCapacity = 3,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val frameFlow: SharedFlow<FrameData> = _frameFlow

    // Called from native
    @Keep
    private fun onNativeFrame(buffer: ByteBuffer, timestampNs: Long, width: Int, height: Int) {
        // Non-blocking emit - drops if consumer too slow
        _frameFlow.tryEmit(FrameData(buffer.duplicate(), timestampNs, width, height))
    }

    fun release() {
        scope.cancel()  // Cancels all collectors
    }
}

// Consumer
lifecycleScope.launch {
    camera.frameFlow
        .buffer(2, BufferOverflow.DROP_OLDEST)
        .flowOn(Dispatchers.Default)
        .collect { frame ->
            processFrame(frame)
        }
}
```

---

## Conclusion

| Migration | Recommendation | Priority |
|-----------|----------------|----------|
| **std::jthread** | ✅ Strongly Recommended | P0 |
| **Kotlin SharedFlow** | ✅ Recommended | P1 |
| **C++20 Coroutines** | ⚠️ Defer | P2 |
| **Async Generator** | ⚠️ Experimental | P3 |

**Rationale:**
- std::jthread provides immediate benefit with minimal risk
- Kotlin SharedFlow integrates well with existing callback architecture
- C++20 coroutines lack mature executor support in Android NDK
- Full coroutine adoption should wait for toolchain maturity

---

## Cross-Reference

| Deliverable | Relationship |
|-------------|--------------|
| **AUDIT-003-appendix-advanced.md** | Lock-free patterns (Appendix A), corrected migration priorities (Appendix F) |
| CONCURRENCY-001 | Threads to migrate |
| CONCURRENCY-002 | Sync primitives, atomic<shared_ptr> warning |
| CONCURRENCY-003 | Blocking operations to transform |
| CONCURRENCY-004 | Frame loop architecture using lock-free buffers |
| CONCURRENCY-005 | Shutdown patterns to improve |
| CONCURRENCY-007 | Scheduling considerations |
| CONCURRENCY-008 | JNI callback patterns |
| CONCURRENCY-010 | Master catalog with updated priorities |

### Important Migration Note

⚠️ **CRITICAL CORRECTION:** Do NOT migrate `pthread_mutex` to `std::atomic<shared_ptr>` as a "medium complexity" improvement. The libc++ implementation uses a global mutex pool and is **blocking**, not lock-free.

**Corrected Migration Path:**
1. `pthread_mutex` guarding frame buffers → Lock-free ring/triple buffer (P0)
2. `volatile bool` → `std::atomic<bool>` (Quick Win)
3. `pthread_create/join` → `std::jthread` with stop_token (P0)

See `AUDIT-003-appendix-advanced.md` Appendix F for the complete corrected priority matrix.

---

*End of CONCURRENCY-009*
