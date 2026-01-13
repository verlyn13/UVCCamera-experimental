# SAFETY-001: Manual Memory Management Inventory

**Audit:** AUDIT-002 Memory Safety Audit
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Summary Statistics

| Metric | Count | Component Breakdown |
|--------|-------|---------------------|
| **malloc** calls | 162 | UVCCamera: 1, libuvc: 11, libusb: 30, libjpeg: 115, other: 5 |
| **calloc** calls | 81 | Mostly libjpeg-turbo |
| **realloc** calls | 18 | Mostly libjpeg-turbo |
| **free** calls | 371 | Distributed across all components |
| **new** expressions | 44 | UVCCamera: 28, libuvc: 0, pipeline: 16 |
| **delete** expressions | 22 | UVCCamera: ~15, pipeline: ~7 |

### Risk Assessment Summary

| Risk Level | Count | Examples |
|------------|-------|----------|
| **Critical** | 3 | Unpaired allocations in error paths |
| **High** | 12 | Size calculations without overflow checks |
| **Medium** | 25 | Manual memory that could use RAII |
| **Low** | 40+ | Third-party code (libjpeg, libusb) |

---

## UVCCamera Core Allocations (Priority 1)

### MM-001: mCaptureBuffer (UVCPreview.cpp)

**Location:** `UVCCamera/UVCPreview.cpp:2413`
**Type:** `malloc`
**Code:**
```cpp
// Line 2411-2413
if (mCaptureBuffer)
    free(mCaptureBuffer);
mCaptureBuffer = static_cast<uint8_t*>(malloc(needed));
```

**Size Expression:** `needed` (computed from width * height * bytes_per_pixel)
**Integer Overflow Risk:** MEDIUM — `needed` is size_t, but source values not validated

**Lifecycle:**
- Allocated: `captureToFd()` / `captureStillFrame()` on demand
- Deallocated: Line 2411 (reallocation), Line 2426 (explicit cleanup)
- Error paths: If malloc fails, `mCaptureBuffer` becomes NULL (handled)

**2026 Mitigation:**
```cpp
// Replace with std::vector<uint8_t>
std::vector<uint8_t> mCaptureBuffer;
// ...
mCaptureBuffer.resize(needed);
```

**Risk Level:** MEDIUM
**Effort:** LOW

---

### MM-002: mUsbFs String (UVCCamera.cpp)

**Location:** `UVCCamera/UVCCamera.cpp:223`
**Type:** `strdup` (calls malloc internally)
**Code:**
```cpp
// Line 222-223
free(mUsbFs);
mUsbFs = strdup(usbfs);
```

**Size Expression:** `strlen(usbfs) + 1`
**Integer Overflow Risk:** LOW (string length)

**Lifecycle:**
- Allocated: `setUsbFs()` via strdup
- Deallocated: Multiple sites (88, 222, 351, 413, 483)
- Error paths: Checked at all exit points (destructor pattern)

**2026 Mitigation:**
```cpp
// Replace with std::string member
std::string mUsbFs;
// ...
mUsbFs = usbfs;
```

**Risk Level:** LOW
**Effort:** LOW

---

### MM-003: Parameters JSON Output (Parameters.cpp)

**Location:** `UVCCamera/Parameters.cpp:315, 339, 393`
**Type:** `strdup`
**Code:**
```cpp
RETURN(strdup(buffer.GetString()), char *);
```

**Lifecycle:**
- Allocated: In getter functions
- Deallocated: CALLER RESPONSIBILITY — **POTENTIAL LEAK**
- Error paths: Not applicable (return value)

**2026 Mitigation:**
```cpp
// Return std::string instead of char*
std::string getParametersJson() const;
// Or use std::string_view if lifetime is guaranteed
```

**Risk Level:** HIGH — Caller may forget to free
**Effort:** LOW

---

### MM-004: new UVCCamera (serenegiant_usb_UVCCamera.cpp)

**Location:** `UVCCamera/serenegiant_usb_UVCCamera.cpp:126`
**Type:** `new`
**Code:**
```cpp
UVCCamera *camera = new UVCCamera();
```

**Lifecycle:**
- Allocated: `nativeCreate()` JNI function
- Deallocated: `nativeDestroy()` via `delete`
- Managed by: HandleManager (slot-based reference counting)

**2026 Mitigation:**
```cpp
// Already well-managed via HandleManager
// Consider std::unique_ptr for internal ownership
auto camera = std::make_unique<UVCCamera>();
auto handle = HandleManager::allocate(std::move(camera));
```

**Risk Level:** LOW (HandleManager provides safety)
**Effort:** MEDIUM

---

### MM-005: new UVCPreview (UVCCamera.cpp)

**Location:** `UVCCamera/UVCCamera.cpp:277`
**Type:** `new`
**Code:**
```cpp
mPreview = new UVCPreview(mDeviceHandle);
```

**Lifecycle:**
- Allocated: `connect()` on successful device open
- Deallocated: `disconnect()` via `SAFE_DELETE(mPreview)`
- Error paths: Covered in destructor

**2026 Mitigation:**
```cpp
std::unique_ptr<UVCPreview> mPreview;
// ...
mPreview = std::make_unique<UVCPreview>(mDeviceHandle);
```

**Risk Level:** LOW
**Effort:** LOW

---

### MM-006: new Callback Objects (UVCCamera.cpp)

**Location:** `UVCCamera/UVCCamera.cpp:274-276`
**Type:** `new`
**Code:**
```cpp
mStatusCallback = new UVCStatusCallback(mDeviceHandle);
mButtonCallback = new UVCButtonCallback(mDeviceHandle);
mReadinessCallback = new UVCReadinessCallback();
```

**Lifecycle:**
- Allocated: `connect()` on successful device open
- Deallocated: `disconnect()` via `SAFE_DELETE()`
- Error paths: All covered in disconnect/destructor

**2026 Mitigation:**
```cpp
std::unique_ptr<UVCStatusCallback> mStatusCallback;
std::unique_ptr<UVCButtonCallback> mButtonCallback;
std::unique_ptr<UVCReadinessCallback> mReadinessCallback;
```

**Risk Level:** LOW
**Effort:** LOW

---

### MM-007: new FrameBufferRing (UVCPreview.cpp)

**Location:** `UVCCamera/UVCPreview.cpp:1564`
**Type:** `new`
**Code:**
```cpp
FrameBufferRing* newRing = new FrameBufferRing();
```

**Lifecycle:**
- Allocated: `switchToRingBufferMode()`
- Deallocated: `destroyRingBuffer()` or ownership transfer
- Error paths: Complex lifecycle with ownership transfer

**2026 Mitigation:**
```cpp
std::unique_ptr<FrameBufferRing> mOwnedRing;
// Use std::unique_ptr with explicit ownership semantics
```

**Risk Level:** MEDIUM (complex ownership)
**Effort:** MEDIUM

---

### MM-008: Pipeline Object Allocations

**Location:** Multiple pipeline files
**Type:** `new`
**Files:**
- `DistributePipeline.cpp:91` — `new DistributePipeline()`
- `ConvertPipeline.cpp:126` — `new ConvertPipeline()`
- `CallbackPipeline.cpp:175` — `new CallbackPipeline()`
- `PreviewPipeline.cpp:219` — `new PreviewPipeline()`
- `SimpleBufferedPipeline.cpp:51` — `new SimpleBufferedPipeline()`
- `PublisherPipeline.cpp:236` — `new PublisherPipeline()`
- `SQLiteBufferedPipeline.cpp:373` — `new SQLiteBufferedPipeline()`

**Lifecycle:**
- Allocated: Factory functions (`create()`)
- Deallocated: Caller responsibility
- Pattern: Factory pattern returning raw pointers

**2026 Mitigation:**
```cpp
// Change factory return type
std::unique_ptr<IPipeline> DistributePipeline::create() {
    return std::make_unique<DistributePipeline>();
}
```

**Risk Level:** MEDIUM
**Effort:** MEDIUM (API change)

---

## libuvc Allocations (Priority 2)

### MM-100: Frame Data Allocation (frame.c)

**Location:** `libuvc/src/frame.c:79, 94`
**Type:** `malloc`
**Code:**
```c
uvc_frame_t *frame = malloc(sizeof(*frame));  // Line 79
frame->data = malloc(data_bytes);              // Line 94
```

**Size Expression:** `data_bytes` (frame size from UVC negotiation)
**Integer Overflow Risk:** LOW (UVC protocol limits)

**Lifecycle:**
- Allocated: `uvc_allocate_frame()`
- Deallocated: `uvc_free_frame()`
- Error paths: Partially handled, some early returns leak

**Comment from Code:**
```c
// FIXME using buffer pool is better performance(5-30%) than directory use malloc everytime.
```

**2026 Mitigation:**
```cpp
// Use std::vector or integrate with AHardwareBuffer
std::vector<std::byte> frame_data;
// Or AHardwareBuffer for zero-copy
```

**Risk Level:** HIGH (hot path, performance critical)
**Effort:** HIGH (architectural change)

---

### MM-101: Stream Buffers (stream.c)

**Location:** `libuvc/src/stream.c:1371-1372, 1597, 1613`
**Type:** `malloc`
**Code:**
```c
strmh->outbuf = malloc(LIBUVC_XFER_BUF_SIZE);   // Line 1371
strmh->holdbuf = malloc(LIBUVC_XFER_BUF_SIZE);  // Line 1372
strmh->transfer_bufs[transfer_id] = malloc(total_transfer_size);  // Line 1597
```

**Lifecycle:**
- Allocated: `uvc_stream_open_ctrl()`
- Deallocated: `uvc_stream_close()`
- Error paths: Some leaks on early error returns

**2026 Mitigation:**
```cpp
// Use std::vector or unique_ptr<uint8_t[]>
std::unique_ptr<uint8_t[]> outbuf;
std::unique_ptr<uint8_t[]> holdbuf;
std::vector<std::unique_ptr<uint8_t[]>> transfer_bufs;
```

**Risk Level:** HIGH (memory leak on error)
**Effort:** MEDIUM

---

### MM-102: Device Structures (device.c)

**Location:** `libuvc/src/device.c:202, 232, 610, 652`
**Type:** `malloc`
**Code:**
```c
*device = malloc(sizeof(uvc_device_t/* *device */));
```

**Lifecycle:**
- Allocated: Device enumeration/open
- Deallocated: `uvc_unref_device()`, `uvc_close()`
- Reference counted: Uses `ref_count` field

**2026 Mitigation:**
```cpp
// Use std::shared_ptr for reference counting
std::shared_ptr<uvc_device_t> device;
```

**Risk Level:** MEDIUM
**Effort:** HIGH (API change across library)

---

## libusb Allocations (Priority 3)

### MM-200: Device Handle (core.c)

**Location:** `libusb/libusb/core.c:1202`
**Type:** `malloc`
**Code:**
```c
_handle = malloc(sizeof(*_handle) + priv_size);
```

**2026 Note:** Third-party library — document but don't modify directly

---

### MM-201: Descriptor Parsing (descriptor.c)

**Location:** `libusb/libusb/descriptor.c` (multiple sites)
**Type:** `malloc`
**Sites:** Lines 192, 341, 566, 790, 907, 960, 1102, 1189, 1309, 1367

**2026 Note:** Third-party library — consider upstream patches or vendored fork

---

## libjpeg-turbo Allocations (Priority 4)

**Note:** 115+ malloc calls, 80+ calloc calls — third-party codec library.

**Strategy:** Do not modify; use as-is or replace with newer version.

---

## Master Allocation Summary

### By Component

| Component | malloc | calloc | realloc | free | new | delete | Risk |
|-----------|--------|--------|---------|------|-----|--------|------|
| UVCCamera Core | 1 | 0 | 0 | 9 | 28 | 15 | Medium |
| UVCCamera Pipeline | 0 | 0 | 0 | 0 | 16 | 7 | Medium |
| libuvc | 11 | 0 | 0 | 18 | 0 | 0 | High |
| libusb | 30 | 2 | 0 | 50 | 0 | 0 | Medium |
| libjpeg-turbo | 115 | 79 | 18 | 290 | 0 | 0 | Low (third-party) |
| rapidjson/test | 5 | 0 | 0 | 4 | 0 | 0 | Low |

### By Risk Level

| Risk | Count | Action |
|------|-------|--------|
| Critical | 3 | Fix immediately |
| High | 12 | Fix in Phase 1 |
| Medium | 25 | Fix in Phase 2 |
| Low | 40+ | Third-party, defer |

---

## Critical Hazards Requiring Immediate Attention

### CRITICAL-001: Error Path Leaks in libuvc/stream.c

**Location:** `libuvc/src/stream.c:1371-1613`
**Issue:** Multiple malloc calls with early returns that don't free allocated memory
**Impact:** Memory leak on stream initialization failure
**Fix:** Add goto-based cleanup or RAII wrappers

### CRITICAL-002: Caller-Responsible Allocations in Parameters.cpp

**Location:** `UVCCamera/Parameters.cpp:315, 339, 393`
**Issue:** `strdup()` returns allocated memory, caller must free
**Impact:** Memory leak if caller forgets to free
**Fix:** Return `std::string` instead of `char*`

### CRITICAL-003: Complex Ownership in FrameBufferRing

**Location:** `UVCCamera/UVCPreview.cpp:1564`
**Issue:** Ownership transfer between components without clear semantics
**Impact:** Double-free or leak possible during state transitions
**Fix:** Use `std::unique_ptr` with explicit ownership transfer

---

## C++23 Migration Priority

### Phase 1 (Immediate)
1. UVCCamera core `new`/`delete` → `std::unique_ptr`
2. `strdup` returns → `std::string`
3. `mCaptureBuffer` → `std::vector<uint8_t>`

### Phase 2 (Near-term)
1. Pipeline factories → return `std::unique_ptr`
2. Callback objects → `std::unique_ptr` members

### Phase 3 (Long-term)
1. libuvc frame handling → integrate with `AHardwareBuffer`
2. Stream buffers → `std::vector` or zero-copy buffers

---

## Raw Data References

| File | Description |
|------|-------------|
| `raw/memory-safety/malloc-sites.txt` | All malloc locations |
| `raw/memory-safety/calloc-sites.txt` | All calloc locations |
| `raw/memory-safety/realloc-sites.txt` | All realloc locations |
| `raw/memory-safety/free-sites.txt` | All free locations |
| `raw/memory-safety/new-sites.txt` | All new expressions |
| `raw/memory-safety/delete-sites.txt` | All delete expressions |

---

*End of SAFETY-001*
