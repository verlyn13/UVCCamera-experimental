# SAFETY-007: Hardware Buffer Integration Analysis

**Audit:** AUDIT-002 Memory Safety Audit
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Summary Statistics

| API | Operations | Sites |
|-----|------------|-------|
| **AHardwareBuffer** | 16 distinct ops | 85 references |
| **ANativeWindow** | 12 distinct ops | 42 references |
| **Fence Sync** | 8 operations | 27 references |
| **EGL Interop** | 5 operations | 12 references |

---

## AHardwareBuffer Architecture

### Buffer Lifecycle

```
┌─────────────────────────────────────────────────────────────────┐
│                     AHardwareBuffer Flow                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. ALLOCATE                                                    │
│     AHardwareBuffer_allocate(&desc, &buffer)                    │
│           ↓                                                     │
│  2. PRODUCER WRITE                                              │
│     AHardwareBuffer_lock(buffer, WRITE, fence, &ptr)            │
│     memcpy(ptr, frame_data, size)                               │
│     AHardwareBuffer_unlock(buffer, &fence)                      │
│           ↓                                                     │
│  3. CROSS-PROCESS TRANSFER (optional)                           │
│     AHardwareBuffer_toHardwareBuffer(env, buffer) → Java        │
│           ↓                                                     │
│  4. CONSUMER READ                                               │
│     AHardwareBuffer_acquire(buffer)                             │
│     AHardwareBuffer_lock(buffer, READ, fence, &ptr)             │
│     process(ptr)                                                │
│     AHardwareBuffer_unlock(buffer, &fence)                      │
│     AHardwareBuffer_release(buffer)                             │
│           ↓                                                     │
│  5. DESTROY                                                     │
│     AHardwareBuffer_release(buffer)                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Critical Hardware Buffer Operations

### HB-001: Buffer Allocation (FrameBufferRing)

**Location:** `FrameBufferRing.cpp:133-150`
**Pattern:**
```cpp
AHardwareBuffer_Desc desc = {
    .width = mWidth,
    .height = mHeight,
    .layers = 1,
    .format = mFormat,
    .usage = AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN |
             AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN |
             AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE,
    .stride = 0,  // Computed by driver
    .rfu0 = 0,
    .rfu1 = 0
};

for (int i = 0; i < FRAME_BUFFER_COUNT; i++) {
    int result = AHardwareBuffer_allocate(&desc, &mBuffers[i]);
    if (result != 0) {
        LOGE("Failed to allocate AHardwareBuffer %d, error: %d", i, result);
        destroy();  // Clean up partial allocation
        return result;
    }
}
```

**Good Practices:**
- Error handling on allocation
- Cleanup of partial allocation
- Proper usage flags for CPU+GPU access

**Hazards:**
- Integer overflow in `width * height` for size calculation
- Driver may reject very large allocations silently

---

### HB-002: Buffer Locking with Stride Handling

**Location:** `FrameBufferRing.cpp:286-324`
**Pattern:**
```cpp
// API 29+ path: Get actual stride
res = AHardwareBuffer_lockAndGetInfo(
    mBuffers[idx],
    AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN,
    -1,      // No acquire fence
    nullptr, // Full buffer rect
    &ptr,
    &bytesPerPixel,
    &bytesPerStride
);

// Fallback for API 26-28
AHardwareBuffer_Desc desc;
AHardwareBuffer_describe(mBuffers[idx], &desc);
res = AHardwareBuffer_lock(
    mBuffers[idx],
    AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN,
    -1,      // No acquire fence
    nullptr, // Full buffer rect
    &ptr
);
// Must calculate stride: desc.stride * bytesPerPixel
```

**Hazards:**
1. **API 26-28 Stride Calculation:** Driver stride != width, GPU alignment padding
2. **Stride Overflow:** `desc.stride * bytesPerPixel` may overflow int32
3. **Lock Failure:** Returns null pointer if GPU still using buffer

**Current Mitigation:**
```cpp
if (res != 0) {
    LOGE("Failed to lock AHardwareBuffer for write: %d", res);
    return nullptr;
}
```

---

### HB-003: Fence-Based Synchronization

**Location:** `FrameBufferRing.cpp:244-275`
**Pattern:**
```cpp
// Producer waits for GPU release fence before writing
if (mMetadata[idx].gpuReleaseFenceFd >= 0) {
    mTelemetry.fencePending.store(true, std::memory_order_relaxed);

    // Use poll() as a portable sync fence wait
    struct pollfd pfd;
    pfd.fd = mMetadata[idx].gpuReleaseFenceFd;
    pfd.events = POLLIN;

    int waitResult = poll(&pfd, 1, 16);  // 16ms timeout

    // Record fence wait time for telemetry
    mTelemetry.fencePending.store(false, std::memory_order_relaxed);

    // Always close the fence after wait
    close(mMetadata[idx].gpuReleaseFenceFd);
    mMetadata[idx].gpuReleaseFenceFd = -1;
}
```

**Good Practices:**
- Telemetry tracking for fence waits
- Timeout prevents infinite blocking
- Fence FD properly closed

**Hazards:**
- 16ms timeout may not be sufficient for complex GPU workloads
- Race condition if gpuReleaseFenceFd modified during wait

---

### HB-004: JNI Buffer Transfer

**Location:** `FrameBufferJNI.cpp:215-230`
**Pattern:**
```cpp
AHardwareBuffer *buffer = ring->acquireReadBuffer(&metadata);
if (!buffer) {
    return nullptr;
}

// Convert AHardwareBuffer to Java HardwareBuffer
jobject hwBuffer = AHardwareBuffer_toHardwareBuffer(env, buffer);
if (!hwBuffer) {
    LOGE("AHardwareBuffer_toHardwareBuffer failed");
    ring->releaseReadBuffer();
    return nullptr;
}
```

**Good Practices:**
- Null check on acquire
- Null check on JNI conversion
- Release buffer on failure path

**Hazards:**
- Reference counting must be balanced across JNI boundary
- Java may hold reference after native releases

---

### HB-005: EGL Image Creation from HardwareBuffer

**Location:** `EGLImageHelperJNI.cpp:233-245`
**Pattern:**
```cpp
// Get native AHardwareBuffer from Java HardwareBuffer
AHardwareBuffer* buffer = AHardwareBuffer_fromHardwareBuffer(env, hardwareBuffer);
if (!buffer) {
    LOGE("createEGLImage: Failed to get AHardwareBuffer from HardwareBuffer");
    return 0;
}

// Get EGLClientBuffer from AHardwareBuffer
EGLClientBuffer clientBuffer = eglGetNativeClientBufferANDROID(buffer);
```

**Hazards:**
- `eglGetNativeClientBufferANDROID` is Android-specific extension
- Must validate EGL extension availability

---

## ANativeWindow Integration

### NW-001: Surface Acquisition

**Location:** `serenegiant_usb_UVCCamera.cpp:423`
**Pattern:**
```cpp
ANativeWindow *preview_window = jSurface ? ANativeWindow_fromSurface(env, jSurface) : NULL;
```

**Hazards:**
- Java Surface can be destroyed while native still holds reference
- Must release with `ANativeWindow_release()` when done

---

### NW-002: Buffer Geometry Configuration

**Location:** `UVCPreview.cpp:249, 839`
**Pattern:**
```cpp
ANativeWindow_setBuffersGeometry(mPreviewWindow,
    mFrameWidth, mFrameHeight,
    WINDOW_FORMAT_RGBX_8888);
```

**Hazards:**
- Must call before first lock
- Returns error if window not in valid state

---

### NW-003: Lock/Unlock Cycle

**Location:** `UVCPreview.cpp:351-375`
**Pattern:**
```cpp
ANativeWindow_Buffer buffer;
if (LIKELY(ANativeWindow_lock(mCaptureWindow, &buffer, NULL) == 0)) {
    // Write to buffer.bits
    copyFrame((const uint8_t *)mCaptureBuffer, (uint8_t *)buffer.bits,
              mFrameWidth, mFrameHeight * 2, mFrameWidth * 2, buffer.stride * 2);
    ANativeWindow_unlockAndPost(mCaptureWindow);
}
```

**Hazards:**
1. **Lock Failure:** Silent if `ANativeWindow_lock` fails
2. **Stride Mismatch:** `buffer.stride` may differ from `mFrameWidth`
3. **Buffer Lifetime:** `buffer.bits` invalid after unlock

---

### NW-004: Proper Release Pattern

**Location:** `UVCPreview.cpp:510-516`
**Pattern:**
```cpp
if (mPreviewWindow) {
    ANativeWindow_release(mPreviewWindow);
    mPreviewWindow = NULL;
}
if (mCaptureWindow) {
    ANativeWindow_release(mCaptureWindow);
    mCaptureWindow = NULL;
}
```

**Good Practice:** Sets to NULL after release to prevent double-free

---

## Fence Synchronization Details

### Bidirectional Fence Protocol

```
┌──────────────────────────────────────────────────────────────────┐
│                   Fence-First Pattern                            │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  PRODUCER (Camera Thread)         CONSUMER (Render Thread)      │
│  ─────────────────────────       ──────────────────────────     │
│                                                                  │
│  1. Wait gpuReleaseFence          4. acquireReadBuffer()        │
│     poll(fence, 16ms)                                           │
│                                   5. Import acquireFence         │
│  2. lockWriteBuffer()                eglCreateSyncKHR()         │
│     AHardwareBuffer_lock()                                      │
│                                   6. eglWaitSyncKHR()           │
│  3. unlockWriteBuffer()              (GPU waits for CPU)        │
│     AHardwareBuffer_unlock()                                    │
│     → produces acquireFence       7. Render using buffer        │
│                                                                  │
│                                   8. createReleaseFence()        │
│                                      eglDupNativeFenceFDANDROID │
│                                                                  │
│                                   9. setGpuReleaseFence()        │
│                                      → for next producer cycle   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Fence FD Lifecycle

| Operation | FD State | Responsibility |
|-----------|----------|----------------|
| `AHardwareBuffer_unlock` | Creates | Producer |
| `acquireFenceFd` stored | Held | FrameSlotMetadata |
| Consumer duplicates | Copied | Java/EGL layer |
| Original consumed | Closed | Consumer on read |
| `gpuReleaseFenceFd` stored | Held | FrameSlotMetadata |
| Producer waits | poll() | Producer on next write |
| Producer closes | Closed | After poll() returns |

---

## Memory Safety Hazards Summary

| ID | Hazard | Severity | Location | Mitigation |
|----|--------|----------|----------|------------|
| HB-001 | Integer overflow in allocation | Medium | FrameBufferRing.cpp:133 | Validate dimensions |
| HB-002 | Stride mismatch on API 26-28 | Medium | FrameBufferRing.cpp:306 | Use lockAndGetInfo on API 29+ |
| HB-003 | Fence timeout too short | Low | FrameBufferRing.cpp:260 | Increase to 32ms |
| HB-004 | Ref count imbalance across JNI | High | FrameBufferJNI.cpp | RAII wrappers |
| NW-001 | Surface destroyed while held | High | serenegiant_usb_UVCCamera.cpp | Weak reference |
| NW-002 | Stride != width assumption | Medium | UVCPreview.cpp:359 | Always use buffer.stride |
| NW-003 | Buffer use after unlock | High | copyFrame patterns | Don't store buffer.bits |

---

## RAII Wrappers for 2026

### AHardwareBuffer Wrapper

```cpp
class UniqueHardwareBuffer {
    AHardwareBuffer* buffer_ = nullptr;
public:
    UniqueHardwareBuffer() = default;
    explicit UniqueHardwareBuffer(AHardwareBuffer* b) : buffer_(b) {}

    ~UniqueHardwareBuffer() {
        if (buffer_) AHardwareBuffer_release(buffer_);
    }

    UniqueHardwareBuffer(UniqueHardwareBuffer&& o) noexcept
        : buffer_(std::exchange(o.buffer_, nullptr)) {}

    UniqueHardwareBuffer& operator=(UniqueHardwareBuffer&& o) noexcept {
        if (this != &o) {
            if (buffer_) AHardwareBuffer_release(buffer_);
            buffer_ = std::exchange(o.buffer_, nullptr);
        }
        return *this;
    }

    // Non-copyable
    UniqueHardwareBuffer(const UniqueHardwareBuffer&) = delete;
    UniqueHardwareBuffer& operator=(const UniqueHardwareBuffer&) = delete;

    AHardwareBuffer* get() const { return buffer_; }
    AHardwareBuffer* release() { return std::exchange(buffer_, nullptr); }
    explicit operator bool() const { return buffer_ != nullptr; }
};
```

### ANativeWindow Wrapper

```cpp
class UniqueNativeWindow {
    ANativeWindow* window_ = nullptr;
public:
    UniqueNativeWindow() = default;
    explicit UniqueNativeWindow(ANativeWindow* w) : window_(w) {}

    ~UniqueNativeWindow() {
        if (window_) ANativeWindow_release(window_);
    }

    // Move-only (same pattern as above)

    ANativeWindow* get() const { return window_; }
    void reset(ANativeWindow* w = nullptr) {
        if (window_) ANativeWindow_release(window_);
        window_ = w;
    }
};
```

### Locked Buffer Scope Guard

```cpp
class HardwareBufferLock {
    AHardwareBuffer* buffer_;
    void* ptr_ = nullptr;
    bool locked_ = false;
public:
    HardwareBufferLock(AHardwareBuffer* buffer, uint64_t usage)
        : buffer_(buffer) {
        if (AHardwareBuffer_lock(buffer, usage, -1, nullptr, &ptr_) == 0) {
            locked_ = true;
        }
    }

    ~HardwareBufferLock() {
        if (locked_) {
            AHardwareBuffer_unlock(buffer_, nullptr);
        }
    }

    explicit operator bool() const { return locked_ && ptr_; }
    void* data() const { return ptr_; }
};
```

---

## Corruption Detection (Already Implemented)

The codebase already implements magic number corruption detection:

```cpp
// FrameBufferRing.h:130-133
static constexpr uint64_t MAGIC_HEADER = 0xFB01CAFEBABE2026ULL;
static constexpr uint64_t MAGIC_FOOTER = 0xFB01DEADBEEF2026ULL;
static constexpr uint64_t MAGIC_POISON = 0xDEADD00DDEADD00DULL;

bool validateMagic() const;
void validateOrAbort(const char* context) const;
void poisonMagicHeaders();
```

**Good Practice:** Detects use-after-free and buffer overruns at runtime.

---

## V4L2 data_offset Integration

### NV12 Plane Offset Requirements

When outputting NV12 to video encoders or display, proper plane offset calculation is critical:

```cpp
// Gralloc determines actual stride (may include padding)
size_t y_plane_size = aligned_stride * height;

// UV plane offset for encoder
v4l2_plane planes[2];
planes[0].m.fd = dmabuf_fd;
planes[0].data_offset = 0;           // Y starts at 0
planes[1].m.fd = dmabuf_fd;          // Same FD (single allocation)
planes[1].data_offset = y_plane_size; // UV starts after padded Y
```

### The "Green Line" Failure Mode

If `data_offset` is calculated using logical size instead of aligned size:
- UV data read from wrong location
- YUV (0,0,0) -> Green in RGB
- Visible as green bar at bottom of frame

### AHardwareBuffer NV12 Integration

```cpp
AHardwareBuffer_Desc desc = {
    .width = width,
    .height = height,
    .layers = 1,
    .format = AHARDWAREBUFFER_FORMAT_YCbCr_420_SP,  // NV12
    .usage = AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN |
             AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE |
             AHARDWAREBUFFER_USAGE_VIDEO_ENCODE,
};

// Get plane info including correct offset
AHardwareBuffer_Planes planes;
AHardwareBuffer_lockPlanes(buffer, usage, -1, nullptr, &planes);

// planes.planes[1].data points to UV plane (offset applied correctly)
// planes.planes[1].rowStride gives actual UV stride
```

**Critical:** Never assume UV offset = `width * height`. Always query from AHardwareBuffer.

**Reference:** See **AUDIT-002-appendix-advanced.md** Appendix E for full V4L2 data_offset details and kernel version requirements.

---

## Migration Priority

### Phase 1 (Immediate)
1. Add UniqueHardwareBuffer wrapper
2. Add UniqueNativeWindow wrapper
3. Add scope guards for lock/unlock

### Phase 2 (Near-term)
1. Migrate all buffer allocation to RAII
2. Add stride validation on all write paths
3. Increase fence timeout to 32ms
4. **Add V4L2 data_offset handling for NV12**

### Phase 3 (Long-term)
1. Implement zero-copy path for supported formats
2. Add GPU composition fallback for unsupported formats
3. Profile and optimize fence wait patterns

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **AUDIT-002-appendix-advanced.md** | V4L2 data_offset (Appendix E), AHardwareBuffer NV12 |
| **AUDIT-001-appendix-background.md** | Kernel version requirements (C.1), GKI standardization |
| SAFETY-002 | Buffer boundary analysis, stride handling |
| CONCURRENCY-004 | Frame ring buffer using AHardwareBuffer |
| INVENTORY-006 | Platform target metrics |

---

*End of SAFETY-007*
