# JNI-003: Frame Delivery Pattern Analysis

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** Frame delivery paths from native to Java
**Status:** Complete

---

## Summary

| Metric | Value |
|--------|-------|
| Frame Delivery Paths | 3 |
| Primary Path | AHardwareBuffer (RING_BUFFER mode) |
| Legacy Path | ByteBuffer callback |
| Zero-Copy Achieved | Yes (RING_BUFFER + EGL) |

---

## 1. Output Mode Architecture

The codebase implements a modern **OutputMode** pattern as the Single Source of Truth for frame routing.

### 1.1 OutputMode Enum

**Location:** `OutputMode.h`

```cpp
enum class OutputMode : int32_t {
    IDLE = 0,           // WARM state - capture only, no display
    DIRECT_WINDOW = 1,  // Legacy ANativeWindow path
    RING_BUFFER = 2     // Modern AHardwareBuffer path
};
```

### 1.2 Mode Comparison

| Mode | Display | Capture | GPU | Zero-Copy | Use Case |
|------|---------|---------|-----|-----------|----------|
| IDLE | No | Yes | N/A | Yes | Background, Gallery view |
| DIRECT_WINDOW | Yes | Yes | No | Yes | Legacy fallback |
| RING_BUFFER | Yes | Yes | Yes | Yes | **Production path** |

### 1.3 Broadcaster Pattern

```
┌─────────────────────────────────────────────────────────────────────┐
│                    BROADCASTER PATTERN                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  USB Frame Received                                                  │
│       │                                                              │
│       ▼                                                              │
│  ┌─────────────────────┐                                            │
│  │  MJPEG → RGBX       │  Decode to CPU buffer                      │
│  │  Conversion         │                                            │
│  └──────────┬──────────┘                                            │
│             │                                                        │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │  Capture Callback   │  FIRST: Always emits (all modes)          │
│  │  (ICaptureFrame)    │  → Photo capture, ML inference             │
│  └──────────┬──────────┘                                            │
│             │                                                        │
│             ▼                                                        │
│  ┌─────────────────────┐                                            │
│  │  OutputMode Switch  │  THEN: Route based on mode                 │
│  └──────────┬──────────┘                                            │
│             │                                                        │
│    ┌────────┼────────┬────────────────┐                              │
│    │        │        │                │                              │
│    ▼        ▼        ▼                │                              │
│  IDLE   DIRECT    RING               │                              │
│  Mode   WINDOW    BUFFER             │                              │
│    │        │        │                │                              │
│    ▼        ▼        ▼                │                              │
│  Discard  ANative  AHardware-        │                              │
│  Frame   Window    Buffer            │                              │
│    │        │        │                │                              │
│    │        │        ▼                │                              │
│    │        │   EGLImage             │                              │
│    │        │   → Texture            │                              │
│    │        │        │                │                              │
│    │        ▼        ▼                │                              │
│    │      Display  Display           │                              │
│    │                                  │                              │
│    └────────── No display ───────────┘                              │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Frame Delivery Paths

### 2.1 Path 1: AHardwareBuffer Ring (RING_BUFFER mode) - Primary

**Components:**
- `FrameBufferRing` - Triple-buffered AHardwareBuffer ring
- `EGLImageHelper` - Zero-copy GPU texture binding
- `FrameSlotMetadata` - Per-slot timing and sync fences

**Flow:**
```
USB Frame → MJPEG decode → AHardwareBuffer_lock() → memcpy to GPU-visible buffer
         → AHardwareBuffer_unlock() → acquireFence
         → Consumer: AHardwareBuffer_toHardwareBuffer() → EGLImage → GL texture
```

**JNI Methods:**
| Method | Purpose |
|--------|---------|
| `nativeFrameBufferAllocate` | Create ring buffer |
| `nativeFrameBufferAcquireBuffer` | Get next frame (returns HardwareBuffer) |
| `nativeFrameBufferReleaseBuffer` | Return buffer to pool |
| `nativeFrameBufferReleaseWithFence` | Return with GPU release fence |
| `nativeCreateEGLImageFromHardwareBuffer` | Bind to GPU texture |

**Zero-Copy Evidence:**
```cpp
// FrameBufferRing.cpp:133-139
AHardwareBuffer_Desc desc = {
    .width = width,
    .height = height,
    .layers = 1,
    .format = format,
    .usage = AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN |
             AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE,  // ← GPU-visible!
    .stride = 0  // Let driver choose optimal stride
};
```

### 2.2 Path 2: ANativeWindow (DIRECT_WINDOW mode) - Legacy

**Flow:**
```
USB Frame → MJPEG decode → ANativeWindow_lock() → memcpy → ANativeWindow_unlockAndPost()
```

**JNI Methods:**
| Method | Purpose |
|--------|---------|
| `nativeSetPreviewDisplay` | Set ANativeWindow Surface |
| `nativeStartPreview` | Begin streaming |
| `nativeStopPreview` | Stop streaming |

**Limitations:**
- No GPU integration
- No fence synchronization
- Tearing possible on slow devices

### 2.3 Path 3: ByteBuffer Callback (Legacy API)

**Flow:**
```
USB Frame → MJPEG decode → NewDirectByteBuffer(native_buffer) → IFrameCallback#onFrame(ByteBuffer)
```

**JNI Methods:**
| Method | Purpose |
|--------|---------|
| `nativeSetFrameCallback` | Register callback |

**Code:**
```cpp
// UVCPreview.cpp:1416
env->CallVoidMethod(mFrameCallbackObj, iframecallback_fields.onFrame, buf);
```

**Limitations:**
- JNI call per frame (~60Hz overhead)
- ByteBuffer allocation per frame
- Memory copy to Java heap

---

## 3. AHardwareBuffer Integration

### 3.1 Ring Buffer Allocation

```cpp
// FrameBufferRing.cpp:143-148
for (int i = 0; i < FRAME_BUFFER_COUNT; i++) {
    int result = AHardwareBuffer_allocate(&desc, &mBuffers[i]);
    if (result != 0) {
        LOGE("Failed to allocate AHardwareBuffer %d, error: %d", i, result);
        // Cleanup already allocated buffers...
    }
}
```

**Configuration:**
| Parameter | Value | Notes |
|-----------|-------|-------|
| Format | `AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM` | RGBX 32-bit |
| Buffer Count | 3 | Triple buffering |
| Usage | CPU_WRITE + GPU_SAMPLED | Zero-copy pipeline |

### 3.2 Producer Path (Native)

```cpp
// 1. Acquire write slot
void* data = nullptr;
int fenceFd = -1;
int res = AHardwareBuffer_lockAndGetInfo(
    mBuffers[idx],
    AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN,
    fenceFd,  // Wait for consumer fence
    nullptr,  // No rect
    &data,
    &stride, &height  // Get actual dimensions
);

// 2. Write frame data
memcpy(data, decodedFrame, frameSize);

// 3. Release and get acquire fence
AHardwareBuffer_unlock(mBuffers[idx], &fenceFd);
// fenceFd passed to consumer via metadata
```

### 3.3 Consumer Path (Kotlin via JNI)

```kotlin
// Kotlin side
val hardwareBuffer = FrameBufferManager.nativeFrameBufferAcquireBuffer(ringHandle)
val acquireFence = FrameBufferManager.nativeFrameBufferGetAcquireFence(ringHandle)

// EGL integration
val eglImage = EGLImageHelper.nativeCreateEGLImageFromHardwareBuffer(display, hardwareBuffer)
EGLImageHelper.nativeGlEGLImageTargetTexture2DOES(textureId, eglImage)

// After rendering, signal release fence
val releaseFence = EGLImageHelper.nativeCreateReleaseFence(display)
FrameBufferManager.nativeFrameBufferReleaseWithFence(ringHandle, frameNumber, releaseFence)
```

---

## 4. Fence Synchronization

### 4.1 Bidirectional Fence Protocol

```
┌────────────────────────────────────────────────────────────────────┐
│                    FENCE SYNCHRONIZATION                            │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Producer (Native Thread)          Consumer (GPU Thread)            │
│                                                                     │
│  writeBuffer(frame)                                                 │
│       │                                                             │
│       ▼                                                             │
│  AHardwareBuffer_lock(write, releaseFence)                         │
│       │ ← Waits for consumer releaseFence                          │
│       │                                                             │
│       ▼                                                             │
│  memcpy(decoded_frame)                                              │
│       │                                                             │
│       ▼                                                             │
│  AHardwareBuffer_unlock() → acquireFence                           │
│       │                      │                                      │
│       │                      ▼                                      │
│       │              Consumer receives acquireFence                 │
│       │                      │                                      │
│       │                      ▼                                      │
│       │              EGL wait for acquireFence                      │
│       │                      │                                      │
│       │                      ▼                                      │
│       │              GL texture sample                              │
│       │                      │                                      │
│       │                      ▼                                      │
│       │              eglCreateSync() → releaseFence                 │
│       │                      │                                      │
│       ▼                      │                                      │
│  Next frame: lock(releaseFence) ◄────────────┘                     │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

### 4.2 JNI Fence Methods

| Method | Direction | Purpose |
|--------|-----------|---------|
| `nativeFrameBufferGetAcquireFence` | Producer→Consumer | GPU must wait before sampling |
| `nativeFrameBufferReleaseWithFence` | Consumer→Producer | Producer can reuse slot |
| `nativeImportNativeFence` | Import to EGL | Convert Android fence FD to EGLSync |
| `nativeCreateReleaseFence` | Export from EGL | Convert GL flush to Android fence FD |

---

## 5. Frame Delivery Metrics

### 5.1 Per-Path Latency

| Path | JNI Calls/Frame | Copies | Estimated Latency |
|------|-----------------|--------|-------------------|
| RING_BUFFER | 0 (async) | 1 (decode) | < 2ms |
| DIRECT_WINDOW | 0 | 2 (decode+display) | ~5ms |
| ByteBuffer Callback | 1 | 2+ (heap copy) | ~10ms |

### 5.2 Telemetry Exposure

| Metric | JNI Method |
|--------|------------|
| Frames received | `nativeFrameBufferGetFramesReceived` |
| Frames rendered | `nativeFrameBufferGetFramesRendered` |
| Frames dropped | `nativeFrameBufferGetFramesDropped` |
| Producer stalls | `nativeFrameBufferGetProducerStalls` |
| Consumer starves | `nativeFrameBufferGetConsumerStarves` |
| Decode time (μs) | `nativeFrameBufferGetAvgDecodeTimeUs` |
| Fence wait time (ns) | `nativeFrameBufferGetFenceWaitTimeNs` |

---

## 6. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| JNI-003-001 | Info | Zero-copy pipeline implemented | Production ready |
| JNI-003-002 | Info | Broadcaster pattern for capture | Keep pattern |
| JNI-003-003 | Low | Legacy ByteBuffer path retained | Deprecate gradually |
| JNI-003-004 | Info | Triple buffering prevents tearing | Optimal |
| JNI-003-005 | Info | Bidirectional fencing implemented | GPU-safe |
| JNI-003-006 | Info | OutputMode as Single Source of Truth | Clean architecture |

---

## 7. Cross-Reference

| Document | Relationship |
|----------|--------------|
| **OutputMode.h** | Frame routing enum |
| **FrameBufferRing.h** | Ring buffer implementation |
| **EGLImageHelperJNI.cpp** | GPU texture binding |
| **JNI-001** | Method inventory |
| **JNI-007** | AHardwareBuffer design (upcoming) |

---

*End of JNI-003*
