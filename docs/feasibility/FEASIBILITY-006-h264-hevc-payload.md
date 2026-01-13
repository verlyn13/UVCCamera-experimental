# FEASIBILITY-006: H.264/HEVC Payload Pipeline

**Status:** Complete
**Date:** 2026-01-11
**Author:** Claude
**Depends On:** FEASIBILITY-003 (PTS/SCR Timestamps)

---

## Executive Summary

H.264/HEVC payload support via UVC's frame-based format requires **significant new infrastructure**. Unlike PTS/SCR or Extension Units where the building blocks exist, H.264/HEVC is essentially **not implemented**. The frame-based descriptor parsing exists but lacks GUID interpretation, format negotiation, MediaCodec integration, and timestamp synchronization.

**Key Finding:** This is a **NEW FEATURE**, not a "last mile" fix. The infrastructure gap is substantial compared to other feasibility items.

**Recommendation:** **CONDITIONAL GO** - Valuable but depends on FEASIBILITY-003 completion and requires 3-4 weeks of focused effort.

---

## 1. Current State Analysis

### 1.1 What EXISTS

| Component | Location | Status |
|-----------|----------|--------|
| Frame-based descriptor types | libuvc.h:139-140 | **Defined** |
| Format descriptor parsing | device.c:1308-1331 | **Implemented** |
| Frame descriptor parsing | device.c:1365-1411 | **Implemented** |
| GUID extraction | device.c:1318 | **Stored but unused** |
| Payload processing | stream.c:680-781 | **Generic, no H.264 awareness** |
| VS Error codes (codec-aware) | libuvc.h:71-81 | **Defined** |

### 1.2 What is MISSING

| Component | Gap | Severity |
|-----------|-----|----------|
| Frame format enum for H.264/HEVC | `UVC_FRAME_FORMAT_H264`, `UVC_FRAME_FORMAT_HEVC` not defined | **HIGH** |
| GUID → frame_format mapping | guidFormat extracted but never interpreted | **HIGH** |
| MediaCodec integration | libmediandk not linked, no AMediaCodec usage | **HIGH** |
| NAL unit parsing | Payload processed as opaque blob | **HIGH** |
| Hardware decoder path | Only software conversion exists | **HIGH** |
| Timestamp passthrough | PTS available but not connected (FEASIBILITY-003) | **MEDIUM** |
| Format negotiation | No H.264/HEVC profile/level negotiation | **MEDIUM** |

### 1.3 Evidence: Frame-Based Format Parsing

**device.c:1308-1331** - Format descriptor parsing exists:
```c
uvc_error_t uvc_parse_vs_frame_format(uvc_streaming_interface_t *stream_if,
    const unsigned char *block, size_t block_size) {
    UVC_ENTER();

    uvc_format_desc_t *format = calloc(1, sizeof(*format));

    format->parent = stream_if;
    format->bDescriptorSubtype = block[2];
    format->bFormatIndex = block[3];
    format->bNumFrameDescriptors = block[4];
    memcpy(format->guidFormat, &block[5], 16);  // ← GUID extracted
    format->bBitsPerPixel = block[21];
    format->bDefaultFrameIndex = block[22];
    // ... aspect ratio, interlace, copy protect, variable size

    DL_APPEND(stream_if->format_descs, format);

    UVC_EXIT(UVC_SUCCESS);
    return UVC_SUCCESS;
}
```

**Gap:** The `guidFormat` is stored but never used to determine codec type.

### 1.4 Evidence: No H.264 Frame Format

**libuvc.h:86-110** - Current frame formats:
```c
enum uvc_frame_format {
    UVC_FRAME_FORMAT_UNKNOWN = 0,
    UVC_FRAME_FORMAT_ANY = 0,
    UVC_FRAME_FORMAT_UNCOMPRESSED,
    UVC_FRAME_FORMAT_COMPRESSED,
    UVC_FRAME_FORMAT_YUYV,
    UVC_FRAME_FORMAT_UYVY,
    UVC_FRAME_FORMAT_RGB565,
    UVC_FRAME_FORMAT_RGB,
    UVC_FRAME_FORMAT_BGR,
    UVC_FRAME_FORMAT_RGBX,
    UVC_FRAME_FORMAT_MJPEG,
    UVC_FRAME_FORMAT_GRAY8,
    UVC_FRAME_FORMAT_BY8,
    UVC_FRAME_FORMAT_COUNT,
    // NO H.264, NO HEVC
};
```

### 1.5 Evidence: Software-Only Conversion Pattern

**Current architecture** (all software CPU conversion):
```
USB Payload → Buffer → uvc_any2rgbx() → ANativeWindow_lock() → memcpy → unlock
                            ↓
                    CPU Software Conversion
```

**H.264/HEVC requires** (hardware accelerated):
```
USB Payload → NAL Units → MediaCodec (async) → Surface (hardware) → Display
                               ↓
                    Hardware Decoder
```

This is a fundamentally different pattern requiring new infrastructure.

---

## 2. UVC Specification Analysis

### 2.1 Frame-Based Payload (UVC 1.5 §2.3)

Frame-based payload is used for:
- H.264/AVC video
- HEVC/H.265 video
- VP8/VP9 video
- Other codec-compressed formats

**Descriptor Structure:**

| Offset | Field | Size | Description |
|--------|-------|------|-------------|
| 0 | bLength | 1 | 28 |
| 1 | bDescriptorType | 1 | CS_INTERFACE (0x24) |
| 2 | bDescriptorSubtype | 1 | VS_FORMAT_FRAME_BASED (0x10) |
| 3 | bFormatIndex | 1 | Format identifier |
| 4 | bNumFrameDescriptors | 1 | Number of frame descriptors |
| 5-20 | guidFormat | 16 | **GUID identifying codec** |
| 21 | bBitsPerPixel | 1 | Bits per pixel |
| 22 | bDefaultFrameIndex | 1 | Default frame index |
| 23 | bAspectRatioX | 1 | X aspect |
| 24 | bAspectRatioY | 1 | Y aspect |
| 25 | bmInterlaceFlags | 1 | Interlacing |
| 26 | bCopyProtect | 1 | Copy protection |
| 27 | bVariableSize | 1 | Variable frame size flag |

### 2.2 Standard H.264 GUIDs

| Codec | GUID | Notes |
|-------|------|-------|
| H.264 | `H264-0000-0010-8000-00AA00389B71` | ASCII "H264" + Microsoft format suffix |
| H.264 (alt) | Vendor-specific | Some cameras use proprietary GUIDs |
| HEVC | `HEVC-0000-0010-8000-00AA00389B71` | Similar pattern |

**Challenge:** Not all cameras use standard GUIDs.

### 2.3 Payload Header for Frame-Based

Same as uncompressed/MJPEG per UVC §2.4.3.3:
- PTS present if bit 2 of header info set
- SCR present if bit 3 of header info set
- EOF indicates complete NAL unit(s) / access unit

**Critical:** PTS is essential for MediaCodec synchronization.

---

## 3. Implementation Approach

### 3.1 Option A: Direct MediaCodec Integration (Recommended)

**Architecture:**
```
┌─────────────────────────────────────────────────────────────────┐
│                    H.264/HEVC Pipeline                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  USB Payload                                                     │
│       │                                                          │
│       ▼                                                          │
│  ┌────────────────┐                                             │
│  │  NAL Parser    │  Extract NAL units, handle fragmentation    │
│  └────────┬───────┘                                             │
│           │                                                      │
│           ▼                                                      │
│  ┌────────────────┐                                             │
│  │  AMediaCodec   │  Hardware decoder via NDK                   │
│  │  (async mode)  │  Input: NAL + PTS                           │
│  └────────┬───────┘  Output: Surface/ImageReader                │
│           │                                                      │
│           ▼                                                      │
│  ┌────────────────┐                                             │
│  │  Surface       │  Hardware-accelerated display               │
│  │  (ANativeWindow)                                             │
│  └────────────────┘                                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Pros:**
- Hardware acceleration
- Low CPU usage
- Modern Android pattern

**Cons:**
- API 21+ required for NDK MediaCodec
- Async complexity
- Surface lifecycle management

### 3.2 Option B: Software H.264 Decoder (Not Recommended)

Use FFmpeg or similar for software decode.

**Pros:**
- Works on all API levels
- Familiar synchronous pattern

**Cons:**
- Very high CPU usage (UVC cameras often 30fps 1080p)
- Battery drain
- Would require FFmpeg dependency
- Poor performance

### 3.3 Option C: Passthrough to Java Layer

Pass raw NAL units to Java for MediaCodec handling.

**Pros:**
- Simpler native code
- Java has better MediaCodec examples

**Cons:**
- JNI overhead for every frame
- Latency
- Doesn't leverage existing native Surface handling

**Recommendation:** Option A (Direct MediaCodec NDK)

---

## 4. Detailed Implementation Requirements

### 4.1 libuvc Changes

#### 4.1.1 Add Frame Format Enums
```c
// libuvc.h - add to uvc_frame_format enum
UVC_FRAME_FORMAT_H264,
UVC_FRAME_FORMAT_HEVC,
UVC_FRAME_FORMAT_VP8,    // Optional
UVC_FRAME_FORMAT_VP9,    // Optional
```

#### 4.1.2 GUID Mapping Function
```c
// New function needed
enum uvc_frame_format uvc_guid_to_frame_format(const uint8_t guid[16]) {
    // H.264 GUID: "H264" + Microsoft suffix
    static const uint8_t h264_guid[] = {
        'H', '2', '6', '4', 0x00, 0x00, 0x10, 0x00,
        0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
    };

    if (memcmp(guid, h264_guid, 16) == 0)
        return UVC_FRAME_FORMAT_H264;

    // Similar for HEVC...

    return UVC_FRAME_FORMAT_UNKNOWN;
}
```

#### 4.1.3 Update Format Negotiation
```c
// stream.c - uvc_get_stream_ctrl_format_size needs H.264 handling
case UVC_VS_FORMAT_FRAME_BASED:
    format->frame_format = uvc_guid_to_frame_format(format->guidFormat);
    if (format->frame_format == UVC_FRAME_FORMAT_H264) {
        // Set up for frame-based streaming
        ctrl->dwMaxPayloadTransferSize = /* calculate */;
    }
    break;
```

### 4.2 NAL Unit Parser

**Required for H.264:**
- NAL start code detection (0x00000001 or 0x000001)
- NAL unit type identification (SPS, PPS, IDR, etc.)
- Access unit boundary detection
- SPS/PPS extraction for codec initialization

```c
// Proposed interface
typedef struct uvc_nal_unit {
    uint8_t type;           // NAL unit type
    size_t size;            // NAL unit size
    uint8_t *data;          // NAL unit data (no start code)
    uint32_t pts;           // Associated PTS
} uvc_nal_unit_t;

typedef struct uvc_nal_parser {
    uint8_t *sps;           // Cached SPS
    size_t sps_size;
    uint8_t *pps;           // Cached PPS
    size_t pps_size;
    // ... parsing state
} uvc_nal_parser_t;

int uvc_nal_parse_payload(uvc_nal_parser_t *parser,
                          const uint8_t *payload, size_t len,
                          uvc_nal_unit_t **units, size_t *num_units);
```

### 4.3 MediaCodec Integration

#### 4.3.1 Build Changes
```makefile
# Android.mk additions
LOCAL_LDLIBS += -lmediandk  # Requires API 21+
```

#### 4.3.2 New C++ Class
```cpp
// H264Decoder.h - proposed structure
class H264Decoder {
public:
    enum class State { UNINITIALIZED, CONFIGURED, RUNNING, ERROR };

    H264Decoder();
    ~H264Decoder();

    // Configure with SPS/PPS
    int configure(ANativeWindow *surface,
                  const uint8_t *sps, size_t sps_len,
                  const uint8_t *pps, size_t pps_len);

    // Queue NAL unit for decode
    int queueInput(const uint8_t *data, size_t len, int64_t pts_us);

    // Called from async callback
    void onOutputAvailable(int32_t index, AMediaCodecBufferInfo *info);

    void stop();

private:
    AMediaCodec *mCodec;
    ANativeWindow *mSurface;
    State mState;
    std::mutex mMutex;
};
```

#### 4.3.3 Async Processing Pattern
```cpp
// MediaCodec NDK uses async callbacks
void onAsyncInputAvailable(AMediaCodec *codec, void *userdata, int32_t index) {
    // Queue waiting NAL unit
}

void onAsyncOutputAvailable(AMediaCodec *codec, void *userdata,
                            int32_t index, AMediaCodecBufferInfo *info) {
    // Release to Surface for display
    AMediaCodec_releaseOutputBuffer(codec, index, true /* render */);
}

void onAsyncFormatChanged(AMediaCodec *codec, void *userdata, AMediaFormat *format) {
    // Handle resolution/format changes
}
```

### 4.4 Timestamp Synchronization (Depends on FEASIBILITY-003)

**Critical integration point:**

```cpp
// In UVC payload callback
void uvc_h264_frame_callback(uvc_frame_t *frame, void *user_ptr) {
    H264Pipeline *pipeline = (H264Pipeline *)user_ptr;

    // REQUIRES: frame->pts populated (FEASIBILITY-003)
    int64_t pts_us = uvc_pts_to_microseconds(frame->pts);

    // Parse NAL units
    pipeline->parseAndQueue(frame->data, frame->data_bytes, pts_us);
}
```

---

## 5. Android Compatibility

### 5.1 API Level Requirements

| Feature | Min API | Notes |
|---------|---------|-------|
| AMediaCodec (NDK) | 21 (Lollipop) | Core codec API |
| AMediaCodec async | 21 | Async mode |
| AImageReader | 24 (Nougat) | For non-Surface output |
| Hardware buffer | 26 (Oreo) | For HardwareBuffer interop |

**Recommendation:** Target API 21+ for MediaCodec NDK

### 5.2 Codec Support (Device-Dependent)

| Codec | Support | Notes |
|-------|---------|-------|
| H.264/AVC | Universal | All Android 5.0+ devices |
| H.264 High Profile | Common | Most modern devices |
| HEVC/H.265 | Common | API 21+ but hardware varies |
| VP9 | Variable | Not universal |

### 5.3 Decoder Selection

```cpp
// Query available decoders
AMediaCodec *codec = AMediaCodec_createDecoderByType("video/avc");
if (!codec) {
    // Fallback or error
}
```

---

## 6. Risk Assessment

### 6.1 Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Camera doesn't report H.264 format | MEDIUM | HIGH | Document supported cameras |
| Non-standard GUID | HIGH | MEDIUM | GUID detection heuristics |
| MediaCodec initialization failure | LOW | HIGH | Fallback to error message |
| Async timing issues | MEDIUM | MEDIUM | Ring buffer between USB and codec |
| Memory pressure | MEDIUM | HIGH | Careful buffer management |
| PTS drift | MEDIUM | MEDIUM | Depends on FEASIBILITY-003 |

### 6.2 Dependency Risks

| Dependency | Risk | Notes |
|------------|------|-------|
| FEASIBILITY-003 (PTS) | **HIGH** | Essential for A/V sync |
| API 21+ | LOW | Acceptable min version |
| Hardware decoder | LOW | Universal for H.264 |

### 6.3 Testing Challenges

- Requires H.264-capable UVC camera (not all webcams support this)
- Need variety of cameras to test GUID variations
- Performance testing across Android devices
- Edge cases: resolution changes, error recovery

---

## 7. Effort Estimation

### 7.1 Phase 1: libuvc H.264 Awareness

| Task | LOC | Effort |
|------|-----|--------|
| Add frame format enums | 10 | 1 hour |
| GUID mapping function | 50 | 2 hours |
| Update format negotiation | 100 | 4 hours |
| Unit tests | 100 | 4 hours |
| **Phase 1 Total** | ~260 | **1-2 days** |

### 7.2 Phase 2: NAL Unit Parser

| Task | LOC | Effort |
|------|-----|--------|
| NAL unit parser core | 300 | 2-3 days |
| SPS/PPS extraction | 200 | 1-2 days |
| Buffer management | 150 | 1 day |
| Unit tests | 200 | 1-2 days |
| **Phase 2 Total** | ~850 | **5-8 days** |

### 7.3 Phase 3: MediaCodec Integration

| Task | LOC | Effort |
|------|-----|--------|
| H264Decoder class | 400 | 2-3 days |
| Async callback handling | 200 | 1-2 days |
| Surface integration | 150 | 1 day |
| Error handling | 150 | 1 day |
| Build system changes | 20 | 2 hours |
| **Phase 3 Total** | ~920 | **5-7 days** |

### 7.4 Phase 4: UVCPreview Integration

| Task | LOC | Effort |
|------|-----|--------|
| Pipeline switching (MJPEG/YUYV/H.264) | 200 | 1-2 days |
| Surface lifecycle | 150 | 1 day |
| Timestamp sync (with FEASIBILITY-003) | 100 | 1 day |
| **Phase 4 Total** | ~450 | **3-4 days** |

### 7.5 Phase 5: Testing & Documentation

| Task | Effort |
|------|--------|
| Integration testing | 3-5 days |
| Camera compatibility testing | 2-3 days |
| Documentation | 1-2 days |
| **Phase 5 Total** | **6-10 days** |

### 7.6 Summary

| Phase | Effort |
|-------|--------|
| Phase 1: libuvc H.264 awareness | 1-2 days |
| Phase 2: NAL unit parser | 5-8 days |
| Phase 3: MediaCodec integration | 5-7 days |
| Phase 4: UVCPreview integration | 3-4 days |
| Phase 5: Testing & documentation | 6-10 days |
| **Total** | **20-31 days (~3-4 weeks)** |

---

## 8. Comparison with Other Feasibility Items

| Feature | Infrastructure Exists | LOC Change | Effort | ROI |
|---------|----------------------|------------|--------|-----|
| PTS/SCR (FEASIBILITY-003) | 90% | ~50 | 4-6 days | **Very High** |
| XU Framework (FEASIBILITY-005) | 70% | ~600 | 11-14 days | High |
| **H.264/HEVC (This)** | **10%** | **~2500** | **20-31 days** | Medium |

H.264/HEVC is the **largest implementation effort** of all feasibility items because:
1. No existing decode infrastructure
2. Requires new async pattern
3. New external dependency (mediandk)
4. Complex NAL parsing

---

## 9. Recommendation

### 9.1 Decision: **CONDITIONAL GO**

**Conditions:**
1. FEASIBILITY-003 (PTS/SCR) must be completed first
2. Must have at least one H.264-capable UVC camera for testing
3. API 21+ minimum is acceptable for target audience

### 9.2 Rationale

**Benefits:**
- H.264 offers ~10x compression vs MJPEG
- Lower USB bandwidth requirements
- Better quality at same bitrate
- Modern capability expected by users

**Costs:**
- Significant development effort (3-4 weeks)
- Increased code complexity
- Limited camera support (not all webcams do H.264)
- Testing complexity

### 9.3 Phased Implementation

**Recommended order:**
1. Complete FEASIBILITY-003 (PTS/SCR) first
2. Phase 1 & 2 (libuvc + NAL parser) - standalone, testable
3. Phase 3 (MediaCodec) - core integration
4. Phase 4 & 5 (UVCPreview + testing)

### 9.4 Alternative: Defer

If H.264 camera support is not a priority:
- Document the capability gap
- Focus on MJPEG/YUYV optimization
- Revisit when user demand justifies effort

---

## Appendix A: H.264 GUID Reference

### A.1 Standard GUIDs

```c
// H.264/AVC
static const uint8_t GUID_H264[] = {
    0x48, 0x32, 0x36, 0x34,  // "H264"
    0x00, 0x00, 0x10, 0x00,
    0x80, 0x00, 0x00, 0xAA,
    0x00, 0x38, 0x9B, 0x71
};

// HEVC/H.265
static const uint8_t GUID_HEVC[] = {
    0x48, 0x45, 0x56, 0x43,  // "HEVC"
    0x00, 0x00, 0x10, 0x00,
    0x80, 0x00, 0x00, 0xAA,
    0x00, 0x38, 0x9B, 0x71
};
```

### A.2 Vendor Variations

Some cameras use non-standard GUIDs. A detection heuristic may be needed:
- Check first 4 bytes for ASCII codec name
- Check for Microsoft format suffix
- Fall back to probing payload for NAL start codes

---

## Appendix B: MediaCodec NDK Reference

### B.1 Key Functions

```c
// Creation
AMediaCodec *AMediaCodec_createDecoderByType(const char *mime);

// Configuration
media_status_t AMediaCodec_configure(AMediaCodec*, AMediaFormat*,
                                     ANativeWindow*, AMediaCrypto*, uint32_t);

// Async callbacks (API 28+ for full async)
media_status_t AMediaCodec_setAsyncNotifyCallback(AMediaCodec*,
                                                   AMediaCodecOnAsyncNotifyCallback, void*);

// Lifecycle
media_status_t AMediaCodec_start(AMediaCodec*);
media_status_t AMediaCodec_stop(AMediaCodec*);
media_status_t AMediaCodec_delete(AMediaCodec*);
```

### B.2 MIME Types

| Codec | MIME Type |
|-------|-----------|
| H.264/AVC | "video/avc" |
| HEVC/H.265 | "video/hevc" |
| VP8 | "video/x-vnd.on2.vp8" |
| VP9 | "video/x-vnd.on2.vp9" |

---

## Appendix C: VS Error Codes for Codec Streams

The libuvc fork already defines codec-aware error codes (libuvc.h:71-81):

```c
typedef enum uvc_vs_error_code_control {
    UVC_VS_ERROR_CODECTRL_NO_ERROR = 0,
    UVC_VS_ERROR_CODECTRL_PROTECTED = 1,          // Content protection
    UVC_VS_ERROR_CODECTRL_IN_BUFEER_UNDERRUN = 2, // Input buffer underrun
    UVC_VS_ERROR_CODECTRL_DATA_DISCONTINUITY = 3, // PTS discontinuity
    UVC_VS_ERROR_CODECTRL_OUT_BUFEER_UNDERRUN = 4,
    UVC_VS_ERROR_CODECTRL_OUT_BUFEER_OVERRUN = 5,
    UVC_VS_ERROR_CODECTRL_FORMAT_CHANGE = 6,      // Resolution change
    UVC_VS_ERROR_CODECTRL_STILL_CAPTURE_ERROR = 7,
    UVC_VS_ERROR_CODECTRL_UNKNOWN = 8,
} uvc_vs_error_code_control_t;
```

These would be used for error recovery in H.264/HEVC pipeline.

---

*End of FEASIBILITY-006*
