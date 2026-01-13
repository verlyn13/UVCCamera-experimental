# JNI-007: AHardwareBuffer Integration Design

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** Zero-copy frame delivery via AHardwareBuffer
**Status:** Implemented (Phase 4)

---

## Summary

| Metric | Value |
|--------|-------|
| Implementation Status | Production Ready |
| Buffer Count | 3 (triple buffering) |
| Format | RGBX 32-bit |
| API Level | 26+ (29+ recommended) |

---

## 1. Architecture

### 1.1 Zero-Copy Pipeline

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    AHARDWAREBUFFER ZERO-COPY PIPELINE                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  USB                    Native                   Kotlin                     │
│   │                       │                        │                        │
│   │  isochronous          │                        │                        │
│   │  transfer             │                        │                        │
│   ├──────────────────────►│  MJPEG buffer          │                        │
│   │                       │       │                │                        │
│   │                       │       ▼                │                        │
│   │                       │  ┌──────────────┐      │                        │
│   │                       │  │ MJPEG→RGBX   │      │                        │
│   │                       │  │ (libjpeg-    │      │                        │
│   │                       │  │  turbo SIMD) │      │                        │
│   │                       │  └──────┬───────┘      │                        │
│   │                       │         │              │                        │
│   │                       │         ▼              │                        │
│   │                       │  ┌──────────────────┐  │                        │
│   │                       │  │ AHardwareBuffer  │  │                        │
│   │                       │  │ (GPU-visible)    │◄─┼── nativeFrameBuffer    │
│   │                       │  │                  │  │      AcquireBuffer()   │
│   │                       │  └────────┬─────────┘  │                        │
│   │                       │           │            │                        │
│   │                       │      acquireFence      │                        │
│   │                       │           │            ▼                        │
│   │                       │           │      ┌───────────────┐              │
│   │                       │           └─────►│ EGLImage      │              │
│   │                       │                  │ → GL Texture  │              │
│   │                       │                  │ → Compositor  │              │
│   │                       │                  └───────────────┘              │
│   │                       │                        │                        │
│   │                       │                   releaseFence                  │
│   │                       │  ◄─────────────────────┘                        │
│   │                       │  nativeFrameBuffer                              │
│   │                       │  ReleaseWithFence()                             │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Key Components

| Component | File | Purpose |
|-----------|------|---------|
| FrameBufferRing | FrameBufferRing.cpp | Triple-buffered ring |
| FrameSlotMetadata | FrameSlotMetadata.h | Per-slot timing/fence |
| EGLImageHelper | EGLImageHelperJNI.cpp | GPU texture binding |

---

## 2. Buffer Configuration

### 2.1 Allocation

```cpp
// FrameBufferRing.cpp:133-142
AHardwareBuffer_Desc desc = {
    .width = width,
    .height = height,
    .layers = 1,
    .format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM,
    .usage = AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN |
             AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE,
    .stride = 0  // Driver-optimal stride
};

for (int i = 0; i < 3; i++) {
    AHardwareBuffer_allocate(&desc, &mBuffers[i]);
}
```

### 2.2 Usage Flags

| Flag | Purpose |
|------|---------|
| CPU_WRITE_OFTEN | Producer (decode) writes frequently |
| GPU_SAMPLED_IMAGE | Consumer (GL) samples as texture |

---

## 3. Producer API (Native)

### 3.1 Write Flow

```cpp
// 1. Acquire write slot
int idx = acquireWriteBuffer();  // Returns next available

// 2. Lock for CPU write (waits for consumer fence)
void* data;
AHardwareBuffer_lockAndGetInfo(
    mBuffers[idx],
    AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN,
    consumerFenceFd,  // Wait for previous consumer
    NULL,
    &data,
    &stride, &height
);

// 3. Write decoded frame
memcpy(data, decodedFrame, width * height * 4);

// 4. Unlock and get acquire fence
int acquireFence;
AHardwareBuffer_unlock(mBuffers[idx], &acquireFence);

// 5. Store fence in metadata
mMetadata[idx].acquireFenceFd = acquireFence;
```

### 3.2 JNI Exposure

Producer API is internal - not exposed to JNI.

---

## 4. Consumer API (Kotlin via JNI)

### 4.1 Acquire Flow

```kotlin
// 1. Get latest frame
val buffer: HardwareBuffer = nativeFrameBufferAcquireBuffer(ringHandle)
val fence: Int = nativeFrameBufferGetAcquireFence(ringHandle)
val frameNum: Long = nativeFrameBufferGetFrameNumber(ringHandle)

// 2. Import fence to EGL
val eglSync = nativeImportNativeFence(display, fence)
// GL waits on eglSync before sampling

// 3. Bind to texture
val eglImage = nativeCreateEGLImageFromHardwareBuffer(display, buffer)
nativeGlEGLImageTargetTexture2DOES(textureId, eglImage)

// 4. Render...
GL.bindTexture(textureId)
GL.draw()

// 5. Create release fence
val releaseFence = nativeCreateReleaseFence(display)

// 6. Release buffer
nativeFrameBufferReleaseWithFence(ringHandle, frameNum, releaseFence)
```

### 4.2 JNI Methods

| Method | Direction | Signature |
|--------|-----------|-----------|
| `nativeFrameBufferAcquireBuffer` | Native→Kotlin | `(J)Landroid/hardware/HardwareBuffer;` |
| `nativeFrameBufferGetAcquireFence` | Native→Kotlin | `(J)I` |
| `nativeFrameBufferReleaseWithFence` | Kotlin→Native | `(JJI)V` |
| `nativeCreateEGLImageFromHardwareBuffer` | Kotlin→Native | `(EGLDisplay;HardwareBuffer;)J` |

---

## 5. Synchronization

### 5.1 Fence Protocol

| Fence | Direction | Purpose |
|-------|-----------|---------|
| Acquire | Producer→Consumer | Consumer must wait before GPU read |
| Release | Consumer→Producer | Producer can reuse slot after GPU done |

### 5.2 Implementation

```cpp
// Producer waits for release fence before reuse
AHardwareBuffer_lock(buffer, usage, releaseFenceFd, rect, &data);

// Consumer waits for acquire fence before sampling
eglCreateSyncKHR(display, EGL_SYNC_NATIVE_FENCE_ANDROID, attrs);
glWaitSync(sync);
```

---

## 6. API Level Compatibility

### 6.1 Requirements

| API | Feature |
|-----|---------|
| 26+ | AHardwareBuffer basic API |
| 28+ | AHardwareBuffer_toHardwareBuffer |
| 29+ | AHardwareBuffer_lockAndGetInfo (accurate stride) |

### 6.2 Fallback Path

For API 26-28, use ANativeWindow direct path (DIRECT_WINDOW mode).

---

## 7. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| JNI-007-001 | Info | Zero-copy implemented | Production ready |
| JNI-007-002 | Info | Triple buffering | Optimal for smooth playback |
| JNI-007-003 | Info | Bidirectional fencing | GPU-safe |
| JNI-007-004 | Low | API 29+ recommended | Document in requirements |
| JNI-007-005 | Info | SIMD decode integration | Maximizes throughput |

---

## 8. Cross-Reference

| Document | Relationship |
|----------|--------------|
| **FrameBufferRing.cpp** | Core implementation |
| **EGLImageHelperJNI.cpp** | GPU binding |
| **JNI-003** | Frame delivery patterns |
| **OutputMode.h** | RING_BUFFER mode |

---

*End of JNI-007*
