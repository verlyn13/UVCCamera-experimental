# AUDIT-002 Appendix: Advanced Memory Safety Patterns

**Audit:** AUDIT-002 Memory Safety Audit
**Generated:** 2026-01-11
**Project:** ScopeCam - UVCCamera Library Modernization
**Target:** Android 16 (API 36) / C++23

---

## Overview

This appendix documents advanced C++23 memory safety patterns specific to frame processing, including `std::mdspan` usage for image data, cache-aware tiling strategies, and V4L2 buffer integration requirements.

---

## Appendix D: Advanced std::mdspan Considerations for Frame Processing

### D.1 The YUYV Format Challenge

UVCCamera handles YUYV 4:2:2 packed format, which creates a semantic mismatch for C++ abstractions:

**Memory Layout:** `Y0 U0 Y1 V0 Y2 U2 Y3 V2 ...`
- Pixel 0: (Y0, U0, V0)
- Pixel 1: (Y1, U0, V0) - shares chroma with Pixel 0
- Two pixels form a 32-bit "macropixel"

**The Abstraction Problem:**
- `std::span<uint8_t>` loses pixel concept entirely
- `std::mdspan<uint8_t, Height, Width*2>` loses pixel boundaries
- `std::mdspan<uint8_t, Height, Width>` has inconsistent semantics (Y vs U/V depending on x)

---

### D.2 Custom Layout for YUYV (Recommended Pattern)

```cpp
// Map logical pixel coordinates to macropixel indices
struct layout_yuyv_macropixel {
    using index_type = size_t;

    static constexpr auto mapping(index_type y, index_type x,
                                   index_type width, index_type height) {
        // Each macropixel covers 2 horizontal pixels
        return y * (width / 2) + (x >> 1);
    }
};

// Access as 32-bit macropixels containing Y0 U0 Y1 V0
using YUYVFrame = std::mdspan<
    uint32_t,
    std::dextents<size_t, 2>,
    layout_yuyv_macropixel
>;
```

**Benefits:**
- `x >> 1` is single-cycle ARM instruction (vs multiplication)
- 4-byte aligned access optimal for Cortex-X cores
- Format complexity hidden in layout class

---

### D.3 Cache Tiling Strategy for Zero-Copy Pipeline

**The Memory Wall Problem:**

A 4K YUYV frame occupies ~16MB, exceeding typical SLC (8MB on Tensor G5). Linear processing with `std::span` causes:
1. Compulsory cache misses for entire frame
2. Intermediate RGB data evicted before next pipeline stage
3. ~70MB DRAM traffic for Convert + Resize pipeline

**Tiled Processing with std::mdspan:**

```cpp
// Process in L2-resident tiles (256x256 = 128KB per plane)
constexpr size_t TILE_H = 256;
constexpr size_t TILE_W = 256;

for (size_t y = 0; y < height; y += TILE_H) {
    for (size_t x = 0; x < width; x += TILE_W) {
        auto src_tile = std::submdspan(src,
            std::tuple{y, std::min(y + TILE_H, height)},
            std::tuple{x, std::min(x + TILE_W, width)});
        auto dst_tile = std::submdspan(dst, /* same */);

        // Convert + process while tile is L2-resident
        convert_and_process(src_tile, dst_tile);
    }
}
```

**Bandwidth Reduction:**

| Pipeline | Linear (std::span) | Tiled (std::mdspan) |
|----------|-------------------|---------------------|
| Convert + Resize | ~70MB DRAM | ~22MB DRAM |
| **Reduction** | - | **68%** |

---

### D.4 SVE2 Vectorization Considerations (ARMv9)

**The LD4 Instruction:**

SVE2 `LD4B` loads contiguous memory and de-interleaves into 4 vector registers:
```
Memory: Y0 U0 Y1 V0 Y2 U2 Y3 V2 ...
Z0: Y0 Y2 Y4 Y6 ...  (all Y)
Z1: U0 U2 U4 U6 ...  (all U)
Z2: Y1 Y3 Y5 Y7 ...  (all Y)
Z3: V0 V2 V4 V6 ...  (all V)
```

**Compiler Vectorization Failure with layout_stride:**

When `std::mdspan` uses generic `layout_stride`, compilers see:
```cpp
ptr + i * stride  // Non-unit stride assumed
```

The compiler cannot prove contiguity -> falls back to scalar or gather loads (4-8x slower).

**Solution: Custom Accessor with ACLE Intrinsics:**

```cpp
struct sve2_yuyv_accessor {
    template<class Handle, class Offset>
    static auto access(Handle ptr, Offset idx) {
        // Use ARM ACLE intrinsics directly
        return svld4_u8(svptrue_b8(),
                        reinterpret_cast<const uint8_t*>(ptr + idx));
    }
};
```

This hybrid approach retains `mdspan` composability while forcing optimal instruction generation.

---

### D.5 Audit Integration

During buffer boundary analysis (SAFETY-002), identify:

1. **Colorspace conversion functions** - candidates for `std::mdspan` refactor
2. **Frame processing loops** - tiling opportunities
3. **ARM-specific optimizations** - existing NEON/SVE code to preserve or upgrade
4. **Stride handling** - current padding/alignment assumptions

**Key Files to Analyze:**

| File | Pattern | mdspan Opportunity |
|------|---------|-------------------|
| `UVCPreview.cpp` | YUYV->RGBX conversion | `layout_yuyv_macropixel` |
| `FrameBufferRing.cpp` | Frame copies | Tiled processing |
| `libuvc/frame-mjpeg.c` | JPEG decode output | Stride-aware mdspan |

---

## Appendix E: V4L2 data_offset Integration

### E.1 NV12 Plane Offset Requirements

When ScopeCam outputs NV12 to video encoders or display:

**Correct Offset Calculation:**

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

**The "Green Line" Failure Mode:**

If `data_offset` is calculated using logical size instead of aligned size:
- UV data read from wrong location
- YUV (0,0,0) -> Green in RGB
- Visible as green bar at bottom of frame

### E.2 Kernel Version Requirements

| Feature | Kernel Version | GKI Status |
|---------|---------------|------------|
| `data_offset` field | ACK 5.10+ | Standardized |
| KMI stability | ACK 5.10+ | Guaranteed |
| Multi-plane DMABUF | ACK 6.1+ | Full support |

**Reference:** See `AUDIT-001-appendix-background.md` Appendix C.1 for V4L2 data_offset history.

### E.3 Audit Task Addition

Add to buffer boundary analysis (SAFETY-002):

**V4L2 Plane Offset Verification:**

```bash
# Find V4L2 buffer setup
grep -rn 'v4l2_plane\|data_offset\|VIDIOC_QBUF' $JNI_PATH --include="*.c" --include="*.cpp"

# Find NV12/YUV format handling
grep -rn 'NV12\|NV21\|V4L2_PIX_FMT' $JNI_PATH --include="*.c" --include="*.cpp"
```

Document whether the library correctly propagates Gralloc-provided offsets to V4L2 drivers.

### E.4 AHardwareBuffer Integration

When using `AHardwareBuffer` for NV12 frames:

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

AHardwareBuffer* buffer;
AHardwareBuffer_allocate(&desc, &buffer);

// Get plane info including offset
AHardwareBuffer_Planes planes;
AHardwareBuffer_lockPlanes(buffer, usage, -1, nullptr, &planes);

// planes.planes[1].data points to UV plane (offset applied)
// planes.planes[1].rowStride gives actual UV stride
```

**Critical:** Never assume UV offset = `width * height`. Always query from AHardwareBuffer.

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **AUDIT-001-appendix-background.md** | V4L2 kernel context, GKI history |
| **SAFETY-002-buffer-boundaries.md** | Buffer analysis including mdspan candidates |
| **SAFETY-007-hardware-buffers.md** | AHardwareBuffer integration details |
| **CONCURRENCY-004** | Frame pipeline using ring buffer |
| **INVENTORY-006** | Platform target metrics |

---

*End of AUDIT-002 Appendix*
