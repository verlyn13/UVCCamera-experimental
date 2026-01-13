# SAFETY-002: Buffer Boundary Analysis

**Audit:** AUDIT-002 Memory Safety Audit
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Summary Statistics

| Metric | Count |
|--------|-------|
| **(ptr, len) function signatures** | 86 |
| **memcpy/memmove/memset calls** | 238 |
| **Unsafe string functions** | 85 |
| **Computed index patterns `[expr*expr]`** | 580 |
| **2D index patterns `y*width+x`** | 9 (critical) |
| **Colorspace conversion hot paths** | 173 |

### Risk Assessment

| Risk Level | Count | Category |
|------------|-------|----------|
| **Critical** | 4 | Colorspace conversions without bounds checking |
| **High** | 15 | Frame buffer operations |
| **Medium** | 50 | memcpy with computed sizes |
| **Low** | 150+ | Third-party library code |

---

## Critical Buffer Hazards (UVCCamera Core)

### BO-001: convertRgbxToNv21 (CRITICAL)

**Location:** `UVCCamera/UVCPreview.cpp:2461-2488`
**Signature:**
```cpp
void UVCPreview::convertRgbxToNv21(const uint8_t* __restrict rgbx,
                                    uint8_t* __restrict nv21,
                                    int width, int height)
```

**Access Pattern:**
```cpp
for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
        int srcIdx = (y * width + x) * 4;      // RGBX: 4 bytes/pixel
        uint8_t r = rgbx[srcIdx];              // NO BOUNDS CHECK
        uint8_t g = rgbx[srcIdx + 1];
        uint8_t b = rgbx[srcIdx + 2];
        // ...
        yPlane[y * width + x] = ...;           // NO BOUNDS CHECK
        vuPlane[vuIdx] = ...;                  // NO BOUNDS CHECK
    }
}
```

**Vulnerabilities:**
1. No validation: `rgbx` buffer has `width * height * 4` bytes
2. No validation: `nv21` buffer has `width * height * 1.5` bytes
3. Integer overflow: `(y * width + x) * 4` can overflow int
4. Width alignment: Odd widths cause UV plane corruption

**2026 Mitigation:**
```cpp
void convertRgbxToNv21(
    std::mdspan<const std::byte, std::dextents<size_t, 3>> rgbx,  // [h][w][4]
    std::mdspan<std::byte, std::dextents<size_t, 2>> y_plane,      // [h][w]
    std::mdspan<std::byte, std::dextents<size_t, 2>> vu_plane      // [h/2][w]
) {
    // Bounds checking automatic via mdspan
    for (size_t y = 0; y < rgbx.extent(0); y++) {
        for (size_t x = 0; x < rgbx.extent(1); x++) {
            auto r = std::to_integer<uint8_t>(rgbx[y, x, 0]);
            // ...
        }
    }
}
```

**Risk Level:** CRITICAL
**Zero-Copy Compatible:** YES (mdspan is non-owning)
**Effort:** MEDIUM

---

### BO-002: convertRgbxToYuyv (CRITICAL)

**Location:** `UVCCamera/UVCPreview.cpp:2494-2523`
**Signature:**
```cpp
void UVCPreview::convertRgbxToYuyv(const uint8_t* __restrict rgbx,
                                    uint8_t* __restrict yuyv,
                                    int width, int height)
```

**Access Pattern:**
```cpp
for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x += 2) {
        int srcIdx0 = (y * width + x) * 4;
        int srcIdx1 = (y * width + x + 1) * 4;  // x+1 may be OOB if width is odd
        // ...
        int dstIdx = (y * width + x) * 2;
        yuyv[dstIdx] = ...;
        yuyv[dstIdx + 3] = ...;  // +3 access
    }
}
```

**Vulnerabilities:**
1. Odd width: `srcIdx1` reads past buffer end
2. No source buffer size validation
3. No destination buffer size validation
4. Integer overflow in index calculations

**2026 Mitigation:** Same as BO-001, use `std::mdspan`

**Risk Level:** CRITICAL
**Effort:** MEDIUM

---

### BO-003: convertRgbxToI420 (CRITICAL)

**Location:** `UVCCamera/UVCPreview.cpp:2529-2557`
**Signature:**
```cpp
void UVCPreview::convertRgbxToI420(const uint8_t* __restrict rgbx,
                                    uint8_t* __restrict i420,
                                    int width, int height)
```

**Access Pattern:**
```cpp
uint8_t* yPlane = i420;
uint8_t* uPlane = i420 + width * height;
uint8_t* vPlane = uPlane + (width * height / 4);  // Integer division!
```

**Vulnerabilities:**
1. Plane pointer arithmetic assumes contiguous buffer
2. `width * height / 4` truncates for non-divisible dimensions
3. No validation of total I420 buffer size (`width * height * 1.5`)
4. Non-aligned widths cause plane overlap

**Risk Level:** CRITICAL
**Effort:** MEDIUM

---

### BO-004: emitCaptureFrame (HIGH)

**Location:** `UVCCamera/UVCPreview.cpp:2567`
**Signature:**
```cpp
void UVCPreview::emitCaptureFrame(const uint8_t* rgbxData, int width, int height, int64_t timestampNs)
```

**Issue:** Passes raw pointer + dimensions to capture pipeline
**Risk:** Downstream code may not validate buffer bounds

**2026 Mitigation:**
```cpp
void emitCaptureFrame(std::span<const std::byte> rgbxData,
                      FrameDimensions dims,
                      std::chrono::nanoseconds timestamp);
```

**Risk Level:** HIGH
**Effort:** LOW

---

### BO-005: copyFrame (HIGH)

**Location:** `UVCCamera/UVCPreview.cpp:1103`
**Signature:**
```cpp
static void copyFrame(const uint8_t *src, uint8_t *dest,
                      const int width, int height,
                      const int stride_src, const int stride_dest)
```

**Access Pattern:**
```cpp
memcpy(dest, src, width);  // Per-row copy
```

**Vulnerabilities:**
1. Assumes `width <= stride_src` and `width <= stride_dest`
2. No validation of total buffer sizes
3. Called in hot path (every frame)

**Risk Level:** HIGH
**Effort:** LOW

---

## High-Risk Buffer Operations

### BO-100: Frame Data Copy (UVCPreview.cpp:1991)

**Code:**
```cpp
memcpy(destPtr, frame->data, copyBytes);
```

**Context:** Copies UVC frame data to ring buffer
**Risk:** `copyBytes` must match actual buffer sizes
**Mitigation:** Validate `copyBytes <= destBufferSize`

---

### BO-101: Capture Buffer Copy (UVCPreview.cpp:2621)

**Code:**
```cpp
memcpy(mCaptureBuffer, rgbxData, bufferSize);
```

**Risk:** `bufferSize` calculated separately from source
**Mitigation:** Use `std::span` to carry size with data

---

### BO-102: Magic Header/Footer (FrameBufferRing.cpp:671-672)

**Code:**
```cpp
memcpy(headerAscii, &mMagicHeader, 8);
memcpy(footerAscii, &mMagicFooter, 8);
```

**Risk:** Hardcoded size (8 bytes)
**Mitigation:** `static_assert(sizeof(mMagicHeader) == 8)`

---

## (ptr, len) Signature Inventory

### Priority 1: UVCCamera Core

| Function | File:Line | Risk |
|----------|-----------|------|
| `convertRgbxToNv21` | UVCPreview.cpp:2461 | Critical |
| `convertRgbxToYuyv` | UVCPreview.cpp:2494 | Critical |
| `convertRgbxToI420` | UVCPreview.cpp:2529 | Critical |
| `emitCaptureFrame` | UVCPreview.cpp:2567 | High |
| `copyFrame` | UVCPreview.cpp:1103 | High |
| `copyFrame` | PreviewPipeline.cpp:57 | High |

### Priority 2: libuvc

| Function | File:Line | Risk |
|----------|-----------|------|
| `uvc_mjpeg2rgb` | frame-mjpeg.c | High |
| `uvc_mjpeg2yuyv` | frame-mjpeg.c | High |
| Frame callbacks | stream.c | High |

---

## Dangerous Function Usage

### memcpy/memmove/memset (238 calls)

| Component | Count | Risk |
|-----------|-------|------|
| UVCCamera | 25 | Medium-High |
| libuvc | 20 | Medium |
| libusb | 40 | Low (third-party) |
| libjpeg-turbo | 150+ | Low (third-party) |

### Unsafe String Functions (85 calls)

| Function | Count | Component | Risk |
|----------|-------|-----------|------|
| strcpy | 30 | Various | Medium |
| sprintf | 45 | Various | High |
| strcat | 8 | Various | High |
| gets | 2 | libjpeg test | Critical (unused) |

**Recommendation:** Replace with `snprintf`, `strncpy`, `strncat`

---

## Integer Overflow Risks

### Size Calculations

| Expression | Location | Risk |
|------------|----------|------|
| `width * height * 4` | Multiple | HIGH — Use `std::safe_numerics` |
| `width * height * 3` | Conversion | HIGH |
| `width * height * 1.5` | NV21/I420 | HIGH |
| `y * width + x` | All loops | MEDIUM |
| `y * stride + x * bpp` | Frame access | MEDIUM |

### Mitigation Pattern

```cpp
// Before (unsafe)
int size = width * height * 4;
uint8_t* buf = (uint8_t*)malloc(size);

// After (safe)
#include <stdckdint.h>  // C23 or use __builtin_mul_overflow
size_t size;
if (__builtin_mul_overflow(width, height, &size) ||
    __builtin_mul_overflow(size, 4, &size)) {
    return std::unexpected(BufferError::Overflow);
}
auto buf = std::make_unique<std::byte[]>(size);
```

---

## 2D Index Pattern Analysis

All 9 occurrences are in `UVCPreview.cpp` colorspace conversions:

| Line | Pattern | Context |
|------|---------|---------|
| 2469 | `(y * width + x) * 4` | RGBX source index |
| 2476 | `y * width + x` | Y plane write |
| 2482 | `(y / 2) * width + x` | VU plane index |
| 2499 | `(y * width + x) * 4` | YUYV source |
| 2500 | `(y * width + x + 1) * 4` | YUYV source (adjacent pixel) |
| 2516 | `(y * width + x) * 2` | YUYV dest |
| 2538 | `(y * width + x) * 4` | I420 source |
| 2545 | `y * width + x` | I420 Y plane |

**All need `std::mdspan` migration for safety.**

---

## Frame Buffer Access Patterns

### Current Data Flow
```
USB Bulk Transfer
  → libusb buffer (no size validation)
    → libuvc frame->data (malloc'd)
      → UVCPreview conversion (memcpy)
        → Ring buffer slot (AHardwareBuffer)
          → GPU/Java
```

### Risk Points
1. **libusb → libuvc:** Frame size from USB descriptor, not validated
2. **libuvc → UVCPreview:** `frame->data_bytes` field, may not match actual
3. **UVCPreview → RingBuffer:** Size calculated, may overflow
4. **RingBuffer → GPU:** Hardware buffer size fixed at allocation

---

## std::mdspan Migration Guide

### Before: Unsafe 2D Access
```cpp
void process(uint8_t* data, int width, int height, int stride) {
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            data[y * stride + x] = transform(data[y * stride + x]);
        }
    }
}
```

### After: Safe with std::mdspan
```cpp
void process(std::mdspan<uint8_t, std::dextents<size_t, 2>,
             std::layout_stride> data) {
    for (size_t y = 0; y < data.extent(0); y++) {
        for (size_t x = 0; x < data.extent(1); x++) {
            data[y, x] = transform(data[y, x]);  // Bounds-checked
        }
    }
}

// Creating mdspan with stride
auto view = std::mdspan(
    raw_ptr,
    std::layout_stride::mapping(
        std::extents{height, width},
        std::array{stride, 1}
    )
);
```

### Advanced mdspan Patterns

For YUYV format handling and cache-aware tiling, see **AUDIT-002-appendix-advanced.md**:
- **Appendix D.1**: YUYV format abstraction challenges
- **Appendix D.2**: Custom `layout_yuyv_macropixel` for 4-byte aligned access
- **Appendix D.3**: Cache tiling strategy (68% DRAM bandwidth reduction)
- **Appendix D.4**: SVE2 vectorization with custom accessor

---

## Zero-Copy Compatibility

| Pattern | Zero-Copy | Notes |
|---------|-----------|-------|
| `std::span` | ✅ | Non-owning view |
| `std::mdspan` | ✅ | Non-owning 2D view |
| `std::vector` | ❌ | Owns data |
| `AHardwareBuffer` | ✅ | GPU-visible, zero-copy |

**Goal:** All frame data flows through `std::mdspan` views of `AHardwareBuffer`

---

## Raw Data References

| File | Description |
|------|-------------|
| `raw/memory-safety/ptr-len-signatures.txt` | (ptr, len) function signatures |
| `raw/memory-safety/mem-functions.txt` | memcpy/memmove/memset calls |
| `raw/memory-safety/unsafe-string.txt` | strcpy/sprintf/etc. |
| `raw/memory-safety/computed-indices.txt` | Array index expressions |
| `raw/memory-safety/2d-index-pattern.txt` | y*width+x patterns |
| `raw/memory-safety/colorspace-conversion.txt` | Colorspace keywords |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **AUDIT-002-appendix-advanced.md** | Advanced mdspan patterns (Appendix D), V4L2 data_offset (Appendix E) |
| SAFETY-003 | Pointer arithmetic patterns to migrate |
| SAFETY-007 | Hardware buffer integration with stride handling |
| CONCURRENCY-004 | Frame pipeline using these buffers |

---

*End of SAFETY-002*
