# JNI-009: New JNI Interface Specification

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** 2026 JNI interface design specification
**Status:** Design Complete

---

## Summary

| Metric | Value |
|--------|-------|
| Interface Layers | 3 (Core, Frame, Control) |
| JNI Call Frequency | 0 per frame (async) |
| Handle Pattern | HandleManager (generation-encoded) |
| Frame Delivery | AHardwareBuffer zero-copy |

---

## 1. Interface Layers

### 1.1 Core Layer (UVCCamera)

**Purpose:** Camera lifecycle and connection management

| Method | Signature | Purpose |
|--------|-----------|---------|
| `nativeCreate` | `()J` | Create camera instance |
| `nativeDestroy` | `(J)V` | Destroy instance |
| `nativeConnectSimple` | `(JILjava/lang/String;)I` | Connect with FD |
| `nativeRelease` | `(J)I` | Release USB |
| `nativeCleanup` | `(JI)I` | Graduated cleanup |

### 1.2 Frame Layer (FrameBufferManager)

**Purpose:** Zero-copy frame delivery

| Method | Signature | Purpose |
|--------|-----------|---------|
| `nativeFrameBufferAllocate` | `(III)J` | Allocate ring |
| `nativeFrameBufferDestroy` | `(J)V` | Destroy ring |
| `nativeFrameBufferAcquireBuffer` | `(J)HardwareBuffer` | Get frame |
| `nativeFrameBufferReleaseWithFence` | `(JJI)V` | Return frame |

### 1.3 Control Layer (UVCCamera)

**Purpose:** Camera parameter control

| Method | Pattern |
|--------|---------|
| `nativeUpdate[Control]Limit` | Query device capabilities |
| `nativeSet[Control]` | Set parameter value |
| `nativeGet[Control]` | Get current value |

---

## 2. Design Principles

### 2.1 Thin JNI Bridge

```
┌──────────────────────────────────────────────────────────────────────┐
│                    2026 JNI ARCHITECTURE                              │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  Kotlin (Smart)                    Native (Dumb)                      │
│  ─────────────                    ────────────────                    │
│  • Lifecycle management            • Frame processing                 │
│  • Error handling                  • USB communication               │
│  • Resource ownership              • SIMD decode                      │
│  • UI coordination                 • Hardware buffer access           │
│                                                                       │
│  JNI Layer: THIN (type marshaling only)                              │
│                                                                       │
│  Frame Path: ASYNC (zero JNI calls per frame)                        │
│                                                                       │
│  Control Path: LOW-FREQUENCY (~1 Hz, user-initiated)                 │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 Ownership Model

| Resource | Owner | Cross-boundary |
|----------|-------|----------------|
| Camera handle | Kotlin | JNI handle (jlong) |
| Ring buffer | Kotlin | JNI handle (jlong) |
| AHardwareBuffer | Native (per-slot) | HardwareBuffer Java object |
| USB FD | Kotlin | Passed to native, duplicated |
| Surface | Kotlin | ANativeWindow from Surface |

### 2.3 Error Contract

```kotlin
// Kotlin side
sealed class UvcResult {
    data class Success(val value: Any?) : UvcResult()
    data class Error(val code: Int, val message: String) : UvcResult()
}

// Native returns int, Kotlin interprets:
// 0 = success
// -100 = invalid handle
// < 0 = error code from libuvc/libusb
```

---

## 3. Interface Categories

### 3.1 Synchronous (Blocking)

| Category | Methods | Frequency |
|----------|---------|-----------|
| Lifecycle | create, destroy, connect | Once per session |
| Control | set/get parameters | User-initiated |
| Configuration | setPreviewSize, setOutputMode | Setup time |

### 3.2 Asynchronous (Non-blocking)

| Category | Methods | Frequency |
|----------|---------|-----------|
| Frame acquire | acquireBuffer | 30-60 Hz |
| Frame release | releaseWithFence | 30-60 Hz |
| Telemetry | getFramesReceived, etc | On-demand |

---

## 4. Callback Interfaces

### 4.1 Current Callbacks

| Interface | Purpose | Frequency |
|-----------|---------|-----------|
| IStatusCallback | USB status changes | Event-driven |
| IButtonCallback | Hardware button press | Event-driven |
| IReadinessCallback | Connection readiness | Event-driven |
| ICaptureFrameCallback | Photo capture | User-initiated |

### 4.2 Callback Registration

```cpp
// JNI (thin bridge)
static jint nativeSetCaptureCallback(JNIEnv *env, jobject thiz,
    ID_TYPE id_camera, jobject callback) {
    auto ref = getCameraHandleManager().acquire(id_camera);
    if (!ref) return JNI_ERR_INVALID_HANDLE;

    UVCCamera *camera = static_cast<UVCCamera *>(ref.ptr);
    return camera->setCaptureCallback(env, callback);
}

// Native (owns GlobalRef)
int UVCCamera::setCaptureCallback(JNIEnv *env, jobject callback) {
    if (mCallbackObj) {
        env->DeleteGlobalRef(mCallbackObj);
    }
    mCallbackObj = callback ? env->NewGlobalRef(callback) : nullptr;
    return 0;
}
```

---

## 5. Future Interface (C++23)

### 5.1 Expected-based Returns

```cpp
// Future pattern
std::expected<jint, UvcError> nativeConnect(...)

// Bridge converts to:
// - Success: return value
// - Error: throw Java exception + return -1
```

### 5.2 Coroutine Integration

```cpp
// Future: Native async operations
jlong nativeStartCaptureAsync(JNIEnv *env, jobject thiz,
    ID_TYPE id_camera, jobject completionCallback);
```

---

## 6. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| JNI-009-001 | Info | Three-layer design | Clean separation |
| JNI-009-002 | Info | Zero JNI calls per frame | Optimal performance |
| JNI-009-003 | Info | Async frame path | No blocking |
| JNI-009-004 | Low | 81 control methods | Consider codegen |
| JNI-009-005 | Info | Return code pattern | Consistent |

---

## 7. Cross-Reference

| Document | Relationship |
|----------|--------------|
| **JNI-001** | Method inventory |
| **JNI-003** | Frame delivery |
| **JNI-008** | Handle management |

---

*End of JNI-009*
