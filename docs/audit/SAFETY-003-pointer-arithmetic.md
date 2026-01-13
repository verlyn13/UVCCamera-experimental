# SAFETY-003: Pointer Arithmetic Catalog

**Audit:** AUDIT-002 Memory Safety Audit
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Summary Statistics

| Metric | Count |
|--------|-------|
| **Computed index patterns** | 580 |
| **2D access patterns (y*stride+x)** | 9 |
| **Pointer increment/decrement** | ~50 |
| **Pointer offset expressions** | ~200 |

---

## Critical Pointer Arithmetic Sites

### PA-001: Frame Index Calculation (UVCPreview.cpp)

**Location:** `UVCCamera/UVCPreview.cpp:2469`
**Expression:**
```cpp
int srcIdx = (y * width + x) * 4;
uint8_t r = rgbx[srcIdx];
```

**Hazards:**
1. `y * width` may overflow int32
2. Result `* 4` may overflow
3. No bounds check against buffer size

**Migration:**
```cpp
// Use std::mdspan for automatic bounds checking
auto pixel = rgbx_view[y, x];  // Returns span<byte, 4>
```

---

### PA-002: UV Plane Pointer (UVCPreview.cpp)

**Location:** `UVCCamera/UVCPreview.cpp:2465, 2482`
**Expression:**
```cpp
uint8_t* vuPlane = nv21 + width * height;  // Pointer offset
int vuIdx = (y / 2) * width + x;           // Index calculation
vuPlane[vuIdx] = ...;
```

**Hazards:**
1. `width * height` may overflow
2. Pointer arithmetic creates unvalidated offset
3. `vuIdx` calculation assumes proper alignment

**Migration:**
```cpp
// Separate planes with explicit spans
std::span<std::byte> y_plane = nv21_buffer.subspan(0, width * height);
std::span<std::byte> vu_plane = nv21_buffer.subspan(width * height);
```

---

### PA-003: I420 Plane Offsets (UVCPreview.cpp)

**Location:** `UVCCamera/UVCPreview.cpp:2532-2534`
**Expression:**
```cpp
uint8_t* yPlane = i420;
uint8_t* uPlane = i420 + width * height;
uint8_t* vPlane = uPlane + (width * height / 4);
```

**Hazards:**
1. Three cascading pointer offsets
2. Integer division truncation in `/ 4`
3. Non-aligned dimensions cause plane overlap

**Migration:**
```cpp
struct I420Frame {
    std::span<std::byte> y;
    std::span<std::byte> u;
    std::span<std::byte> v;

    static I420Frame from_buffer(std::span<std::byte> buf, size_t w, size_t h) {
        auto y_size = w * h;
        auto uv_size = w * h / 4;
        return {
            buf.subspan(0, y_size),
            buf.subspan(y_size, uv_size),
            buf.subspan(y_size + uv_size, uv_size)
        };
    }
};
```

---

### PA-004: YUYV Adjacent Pixel (UVCPreview.cpp)

**Location:** `UVCCamera/UVCPreview.cpp:2500`
**Expression:**
```cpp
int srcIdx1 = (y * width + x + 1) * 4;  // Adjacent pixel
```

**Hazards:**
1. `x + 1` may exceed width if width is odd
2. Creates out-of-bounds read

**Migration:**
```cpp
// Ensure width is even, or handle edge case
assert(width % 2 == 0);
// Or use mdspan with explicit bounds
```

---

### PA-005: Row Stride Copy (UVCPreview.cpp)

**Location:** `UVCCamera/UVCPreview.cpp:1103-1124`
**Expression:**
```cpp
static void copyFrame(const uint8_t *src, uint8_t *dest,
                      const int width, int height,
                      const int stride_src, const int stride_dest) {
    for (int j = height; j > 0; j--) {
        memcpy(dest, src, width);
        src += stride_src;   // Pointer increment
        dest += stride_dest; // Pointer increment
    }
}
```

**Hazards:**
1. `src += stride_src` may exceed buffer
2. `dest += stride_dest` may exceed buffer
3. `width` may exceed stride values

**Migration:**
```cpp
void copyFrame(
    std::mdspan<const std::byte, std::dextents<size_t, 2>, std::layout_stride> src,
    std::mdspan<std::byte, std::dextents<size_t, 2>, std::layout_stride> dest
) {
    assert(src.extent(0) == dest.extent(0));  // Height match
    assert(src.extent(1) == dest.extent(1));  // Width match
    for (size_t y = 0; y < src.extent(0); y++) {
        std::ranges::copy(src[y], dest[y].begin());
    }
}
```

---

## Pointer Arithmetic Patterns by Risk

### High Risk (Requires Immediate Attention)

| Pattern | Count | Example Location |
|---------|-------|------------------|
| `ptr + (y * w + x)` | 9 | UVCPreview.cpp:2469 |
| `ptr + size_expr` | ~20 | Plane pointer offsets |
| `ptr[computed_idx]` | ~100 | Frame buffer access |

### Medium Risk (Migration Target)

| Pattern | Count | Example |
|---------|-------|---------|
| `ptr++` in loop | ~30 | Row iteration |
| `ptr + constant` | ~50 | Structure field access |
| `*ptr++` | ~10 | Sequential read |

### Low Risk (Third-Party Code)

| Component | Count | Notes |
|-----------|-------|-------|
| libjpeg-turbo | ~300 | Codec internals |
| libusb | ~100 | Transport layer |
| libuvc | ~50 | Protocol handling |

---

## std::mdspan Migration Priority

### Phase 1: Critical (Zero-Copy Frame Path)

| Site | Current | Target |
|------|---------|--------|
| Colorspace conversion | `uint8_t* + offset` | `mdspan<byte, 3>` |
| Frame copy | `memcpy + ptr arithmetic` | `mdspan` views |
| Ring buffer access | `AHardwareBuffer lock` | `mdspan` wrapper |

### Phase 2: Important (Non-Critical Path)

| Site | Current | Target |
|------|---------|--------|
| Capture buffer | `malloc + ptr` | `vector + span` |
| Debug utilities | Various | `span` views |

### Phase 3: Low Priority (Third-Party)

Leave libusb, libuvc, libjpeg-turbo pointer arithmetic as-is.

---

## Code Example: Safe Pointer Arithmetic

### Before (Unsafe)
```cpp
void process(uint8_t* data, int width, int height) {
    for (int y = 0; y < height; y++) {
        uint8_t* row = data + y * width;
        for (int x = 0; x < width; x++) {
            row[x] = transform(row[x]);
        }
    }
}
```

### After (Safe with std::mdspan)
```cpp
void process(std::mdspan<uint8_t, std::dextents<size_t, 2>> data) {
    for (size_t y = 0; y < data.extent(0); y++) {
        for (size_t x = 0; x < data.extent(1); x++) {
            data[y, x] = transform(data[y, x]);  // Bounds-checked
        }
    }
}
```

---

*End of SAFETY-003*
