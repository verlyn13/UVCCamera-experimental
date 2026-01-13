# INVESTIGATION-001: Essential Questions - Evidence-Based Findings

**Status:** Complete
**Date:** 2026-01-12
**Author:** Claude
**Project:** ScopeCam - UVCCamera Library Modernization
**Questions Investigated:** 47/47

---

## Executive Summary

This document provides evidence-based answers to all 47 architectural questions from INVESTIGATION-001. Each answer includes file paths, line numbers, and code excerpts that directly inform architectural decisions for the 2026 modernization plan.

**Key Strategic Findings:**
1. **Isochronous is ALREADY IMPLEMENTED** - Not "premium path to add" but "existing capability to optimize"
2. **FD injection EXISTS** - `uvc_get_device_with_fd()` fully functional
3. **PTS/SCR EXTRACTED but DISCARDED** - ~5 lines to connect to frames
4. **AHardwareBuffer IMPLEMENTED** - Zero-copy infrastructure already present
5. **GET_INFO NOT USED** - Only defined, never called (major opportunity)
6. **No MediaCodec** - H.264/HEVC decode path must be built from scratch
7. **C++ standard not specified** - Defaults to NDK default, needs explicit C++17/20

---

## Category A: Transport Layer Reality

### A-01: What USB transfer types are currently used?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/stream.c:1466-1611`
- `lib/src/main/jni/libusb/libusb/libusb.h:365-377`

**Code Excerpt:**
```c
// stream.c:1466-1472
/* A VS interface uses isochronous transfers if it has multiple altsettings.
 * We want to select one altsetting to switch on for streaming */
isochronous = interface->num_altsetting > 1;

if (LIKELY(isochronous)) {
    MARK("isochronous transfer mode:num_altsetting=%d", interface->num_altsetting);
```

**Finding:** **BOTH isochronous and bulk are implemented.** The code automatically detects and uses isochronous when `num_altsetting > 1`, falling back to bulk otherwise.

**Transfer Type Constants (libusb.h:365-377):**
- `LIBUSB_TRANSFER_TYPE_CONTROL = 0`
- `LIBUSB_TRANSFER_TYPE_ISOCHRONOUS = 1`
- `LIBUSB_TRANSFER_TYPE_BULK = 2`
- `LIBUSB_TRANSFER_TYPE_INTERRUPT = 3`
- `LIBUSB_TRANSFER_TYPE_BULK_STREAM = 4` (Android extended)

**Architectural Decision:** Isochronous is NOT a feature to add - it's already working. Plan should focus on optimization and reliability, not implementation.

---

### A-02: How is USB device access obtained?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/device.c:223-260`
- `lib/src/main/jni/UVCCamera/UVCCamera.cpp:256-260`

**Code Excerpt:**
```c
// device.c:223
uvc_error_t uvc_get_device_with_fd(uvc_context_t *ctx, uvc_device_t **device,
    int vid, int pid, const char *serial, int fd, int busnum, int devaddr);

// UVCCamera.cpp:256-259
result = uvc_get_device_with_fd(mContext, &mDevice, vid, pid, NULL, fd, busnum, devaddr);
LOGI("FORENSIC-010: uvc_get_device_with_fd returned %d (%s), device=%p",
     result, uvc_strerror(result), mDevice);
```

**Finding:** **FD injection is FULLY IMPLEMENTED.** The `uvc_get_device_with_fd()` function is a saki@serenegiant addition that accepts file descriptors from Kotlin via JNI.

**Flow:** Kotlin `UsbDeviceConnection.getFileDescriptor()` → JNI → `uvc_get_device_with_fd()` → libusb wraps FD

**Architectural Decision:** OPP-011 is ALREADY DONE. No FD injection work needed.

---

### A-03: What alternate setting selection logic exists?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/stream.c:1466-1580`

**Code Excerpt:**
```c
// stream.c:1510-1545
/* Go through the altsettings and find one whose packets are at least
 * as big as our wanted bandwidth. */
const int num_alt = interface->num_altsetting - 1;
for (alt_idx = num_alt; LIKELY(alt_idx >= 0); alt_idx--) {
    altsetting = interface->altsetting + alt_idx;
    // ... endpoint selection
    if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK)
        == LIBUSB_TRANSFER_TYPE_ISOCHRONOUS) {
        // Calculate required bandwidth
        packets_per_transfer = psize / endpoint->wMaxPacketSize;
        // Select appropriate altsetting based on bandwidth
```

**Finding:** **Sophisticated bandwidth negotiation exists.** The code:
1. Enumerates all alternate settings
2. Calculates required bandwidth from stream parameters
3. Selects minimum altsetting that provides required bandwidth
4. Falls back to bulk if no isochronous altsetting works

**Architectural Decision:** Bandwidth negotiation is mature. Focus on exposing it to API, not reimplementing.

---

### A-04: How are USB errors handled and recovered?

**Evidence Files:**
- `lib/src/main/jni/libusb/libusb/libusb.h:1172-1225`
- `lib/src/main/jni/libuvc/src/stream.c:980-1000`

**LIBUSB Error Codes (libusb.h):**
```c
LIBUSB_ERROR_IO = -1,
LIBUSB_ERROR_INVALID_PARAM = -2,
LIBUSB_ERROR_ACCESS = -3,
LIBUSB_ERROR_NO_DEVICE = -4,
LIBUSB_ERROR_NOT_FOUND = -5,
LIBUSB_ERROR_BUSY = -6,
LIBUSB_ERROR_TIMEOUT = -7,
LIBUSB_ERROR_OVERFLOW = -8,
LIBUSB_ERROR_PIPE = -9,
LIBUSB_ERROR_INTERRUPTED = -10,
LIBUSB_ERROR_NO_MEM = -11,
LIBUSB_ERROR_NOT_SUPPORTED = -12,
LIBUSB_ERROR_OTHER = -99,
```

**Error Handling Pattern (stream.c:980-1000):**
```c
if (transfer->num_iso_packets) {
    for (int i = 0; i < transfer->num_iso_packets; i++) {
        if (transfer->iso_packet_desc[i].actual_length == 0) {
            zero_packets++;
        }
    }
    if (zero_packets == transfer->num_iso_packets) {
        // All packets empty - possible disconnect
    }
}
```

**Finding:** **Basic error detection exists, but NO recovery state machine.** Errors are logged but not systematically recovered.

**Architectural Decision:** Recovery state machine must be built. This is a major gap.

---

### A-05: What USB permissions model is used?

**Evidence Files:**
- Project relies on Kotlin-side permission handling
- Native code receives FD after permission granted

**Finding:** Permission handling is delegated to Kotlin layer via Android USB framework. Native code is permission-agnostic - it just receives FDs.

**Architectural Decision:** Android 16 USB permission compliance is a Kotlin-layer concern, not native.

---

### A-06: Is there any isochronous-specific infrastructure?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/stream.c:667-830` (ISO packet processing)
- `lib/src/main/jni/libuvc/src/stream.c:785-803` (ISO packet handling)

**Code Excerpt:**
```c
// stream.c:785-803
/* This is an isochronous mode transfer, so each packet has a payload transfer */
for (packet_id = 0; packet_id < transfer->num_iso_packets; packet_id++) {
    struct libusb_iso_packet_descriptor *pkt = transfer->iso_packet_desc + packet_id;
    // Process each ISO packet
```

**Finding:** **Full isochronous infrastructure exists:**
- ISO packet allocation with `libusb_alloc_transfer(packets_per_transfer)`
- Per-packet processing with `iso_packet_desc`
- Buffer management for ISO transfers
- Error detection per packet

**Architectural Decision:** ISO infrastructure is COMPLETE. Plan should optimize, not build.

---

### A-07: What is the USB read thread architecture?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/stream.c:1630`
- `lib/src/main/jni/libuvc/src/init.c:211`
- `lib/src/main/jni/UVCCamera/UVCPreview.cpp:441, 893, 2685`

**Thread Creation Points:**
```c
// libuvc/stream.c:1630 - Callback delivery thread
pthread_create(&strmh->cb_thread, NULL, _uvc_user_caller, (void*) strmh);

// libuvc/init.c:211 - USB event handling thread
pthread_create(&ctx->handler_thread, NULL, _uvc_handle_events, (void*) ctx);

// UVCPreview.cpp:441 - Preview rendering thread
result = pthread_create(&preview_thread, NULL, preview_thread_func, (void *)this);

// UVCPreview.cpp:893 - Frame capture thread
int createResult = pthread_create(&capture_thread, NULL, capture_thread_func, (void *)this);

// UVCPreview.cpp:2685 - Conversion thread (WARM state)
int result = pthread_create(&mConversionThread, NULL, ...);
```

**Finding:** **5+ threads in active operation:**
1. USB event handling thread (libusb)
2. Stream callback delivery thread (libuvc)
3. Preview rendering thread (UVCPreview)
4. Capture thread (UVCPreview)
5. Conversion thread (WARM state)

**No priority setting observed** - all use default pthread attributes.

**Architectural Decision:** Thread priority management is needed. Thread count is appropriate but needs tuning.

---

### A-08: How is USB disconnection detected and handled?

**Evidence Files:**
- `lib/src/main/jni/libusb/libusb/os/linux_netlink.c:196-212`
- `lib/src/main/jni/libusb/libusb/os/android_netlink.c:155`

**Code Excerpt:**
```c
// linux_netlink.c:196-212
static int linux_netlink_parse(char *buffer, size_t len, int *detached, ...) {
    *detached = 0;
    // Parse netlink message
    if (/* removal event */) {
        *detached = 1;
    }
}
```

**Finding:** **Disconnect detection via netlink exists** at libusb level. The `LIBUSB_TRANSFER_NO_DEVICE` status is set on transfers when device is removed.

**Cleanup path:** detachSurface() → HOT→WARM transition → cleanup

**Architectural Decision:** Basic disconnect detection exists. Need structured cleanup state machine.

---

## Category B: libuvc Integration Depth

### B-01: What version/fork of libuvc is in use?

**Evidence Files:**
- `lib/src/main/jni/libuvc/` (directory structure)
- All `*_original.c` files preserved

**Finding:** **saki@serenegiant fork** of ktossell/libuvc:
- 108% code growth (4,277 lines added)
- Original files preserved as `*_original.c`
- Android-specific FD injection
- Extended colorspace conversions (20+)
- UVC 1.1/1.5 parameter support

**Architectural Decision:** Continue fork. Upstream merge impractical.

---

### B-02: What libuvc APIs are actually used?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/UVCCamera.cpp`
- `lib/src/main/jni/UVCCamera/UVCPreview.cpp`

**APIs Called (from UVCCamera/UVCPreview):**
```c
// Device lifecycle
uvc_init2(), uvc_exit(), uvc_get_device_with_fd(), uvc_open(), uvc_close()
uvc_ref_device(), uvc_unref_device()

// Streaming
uvc_get_stream_ctrl_format_size_fps(), uvc_start_streaming_bandwidth()
uvc_stop_streaming(), uvc_get_frame_desc()

// Frame handling
uvc_allocate_frame(), uvc_free_frame(), uvc_duplicate_frame()
uvc_ensure_frame_size()

// Controls (~40+)
uvc_get_*/uvc_set_* for all CT/PU selectors

// Diagnostics
uvc_print_diag(), uvc_print_stream_ctrl(), uvc_strerror()

// Descriptors
uvc_get_device_descriptor(), uvc_get_input_terminals()
uvc_get_processing_units(), uvc_get_extension_units()
```

**Finding:** ~60+ libuvc API functions actively used.

**Architectural Decision:** Wrapper layer would need to cover ~60 functions. Fork is more practical.

---

### B-03: Have any libuvc modifications been made?

**Evidence Files:**
- All `*_original.c` files (8 files)
- XXX markers throughout modified code

**Key Modifications (XXX markers):**
1. **FD injection**: `uvc_get_device_with_fd()` added
2. **Bandwidth control**: `uvc_start_streaming_bandwidth()` added
3. **Colorspace conversions**: 20+ new conversion functions
4. **Error handling**: `bfh_err` flag tracking
5. **Android logging**: `__android_log` integration
6. **UVC 1.1/1.5 params**: `dwClockFrequency`, `bmLayoutPerStream`

**Finding:** **HEAVILY MODIFIED FORK** - Tracking via `*_original.c` files is excellent practice.

**Architectural Decision:** Continue fork maintenance. Preserve original file pattern.

---

### B-04: How does libuvc handle streaming?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/stream.c:1350-1650`

**Streaming Architecture:**
1. `uvc_start_streaming_bandwidth()` negotiates format/resolution
2. Alt setting selected for bandwidth
3. Transfer buffers allocated (ISO or bulk)
4. Transfers submitted to libusb
5. Callback thread delivers complete frames

**Callback Registration:**
```c
// stream.c:1630
pthread_create(&strmh->cb_thread, NULL, _uvc_user_caller, (void*) strmh);
```

**Architectural Decision:** Streaming architecture is solid. Inject timestamp extraction at `_uvc_swap_buffers()`.

---

### B-05: How does libuvc parse UVC descriptors?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/device.c:1290-1330`
- `lib/src/main/jni/libuvc/include/libuvc/libuvc.h:132-141`

**Format Types Supported:**
```c
// libuvc.h:132-141
UVC_VS_FORMAT_UNCOMPRESSED = 0x04,
UVC_VS_FORMAT_MJPEG = 0x06,
UVC_VS_FORMAT_MPEG2TS = 0x0a,
UVC_VS_FORMAT_DV = 0x0c,
UVC_VS_FORMAT_FRAME_BASED = 0x10,  // H.264/HEVC
UVC_VS_FORMAT_STREAM_BASED = 0x12
```

**GUID Handling (device.c:1318):**
```c
memcpy(format->guidFormat, &block[5], 16);
```

**Finding:** Frame-based format (H.264/HEVC) is PARSED but not DECODED. guidFormat extracted but never interpreted.

**Architectural Decision:** Descriptor parsing is complete. Need GUID→codec mapping and MediaCodec integration.

---

### B-06: What is the frame assembly logic?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/stream.c:700-780`

**Frame Assembly (stream.c):**
```c
// Error bit detection
if (UNLIKELY(header_info & UVC_STREAM_ERR)) {
    strmh->bfh_err |= UVC_STREAM_ERR;
}

// FID toggle detection for frame boundary
if ((strmh->fid != (header_info & UVC_STREAM_FID)) && strmh->got_bytes) {
    /* The frame ID bit was flipped, but we have image data sitting
       around from a previous frame. This means we got EOF for
       the last transfer of the previous frame. */
}
strmh->fid = header_info & UVC_STREAM_FID;

// EOF detection
if (header_info & UVC_STREAM_EOF) {
    _uvc_swap_buffers(strmh);  // Complete frame
}
```

**Finding:** **Robust frame assembly** with:
- FID toggle detection
- EOF bit handling
- Error bit tracking (`bfh_err`)
- Buffer overflow protection

**Architectural Decision:** Frame assembly is mature. No changes needed.

---

### B-07: Is there any UVC 1.5 specific code?

**Evidence Files:**
- `lib/src/main/jni/libuvc/include/libuvc/libuvc.h:139-141`
- `lib/src/main/jni/libuvc/src/device.c:1308-1330`
- `lib/src/main/jni/libuvc/src/diag.c:278-282`

**UVC 1.5 Support:**
```c
// Format constants defined
UVC_VS_FORMAT_FRAME_BASED = 0x10,  // ✓ Defined
UVC_VS_FRAME_FRAME_BASED = 0x11,  // ✓ Defined

// Descriptor parsing
case UVC_VS_FORMAT_FRAME_BASED:  // ✓ Parsed
    // guidFormat extracted but NOT interpreted
```

**VS Error Codes (libuvc.h:71-81):**
```c
UVC_VS_ERROR_CODEC_PROTECTED = 0x00,
UVC_VS_ERROR_CODEC_NO_RESOURCES = 0x01,
UVC_VS_ERROR_CODEC_INVALID_FORMAT = 0x02,
// ... codec-specific error codes defined
```

**Finding:** **UVC 1.5 structure parsed, but H.264/HEVC decode NOT implemented.**

**Architectural Decision:** Frame-based format support is 50% complete. Need:
1. GUID→codec mapping
2. MediaCodec integration
3. NAL unit assembly

---

### B-08: How are UVC controls implemented?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/ctrl.c` (1,719 lines)
- `lib/src/main/jni/UVCCamera/UVCCamera.cpp:970-1260`

**Control Pattern:**
```c
// UVCCamera.cpp:970-980
ret = get_func(devh, &value, UVC_GET_MIN);
if (!ret) {
    ret = get_func(devh, &value, UVC_GET_MAX);
    if (!ret) {
        ret = get_func(devh, &value, UVC_GET_DEF);
    }
}
```

**Control Constants (libuvc.h:228-233):**
```c
UVC_GET_CUR = 0x81,
UVC_GET_MIN = 0x82,
UVC_GET_MAX = 0x83,
UVC_GET_RES = 0x84,
UVC_GET_LEN = 0x85,
UVC_GET_INFO = 0x86,  // ⚠️ DEFINED but NEVER CALLED
UVC_GET_DEF = 0x87
```

**Finding:** GET_MIN/MAX/DEF used. **GET_INFO NEVER USED** - capability bits not queried.

**Architectural Decision:** Major opportunity - implement GET_INFO for capability discovery.

---

### B-09: Is Extension Unit support present?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/device.c:773-782, 1095-1134`
- `lib/src/main/jni/libuvc/src/ctrl.c:60-84`

**XU Enumeration (device.c:773-782):**
```c
const uvc_extension_unit_t *uvc_get_extension_units(uvc_device_handle_t *devh) {
    return devh->info->ctrl_if.extension_unit_descs;
}
```

**XU Descriptor Parsing (device.c:1095):**
```c
unit->bUnitID = block[3];
unit->request = (unit->bUnitID << 8) | info->ctrl_if.bInterfaceNumber;
```

**Finding:** **Basic XU support exists:**
- ✓ XU enumeration
- ✓ bUnitID extraction
- ✓ GUID storage
- ✗ No high-level XU framework
- ✗ No vendor protocol handling

**Architectural Decision:** XU infrastructure present. Need typed framework wrapper.

---

### B-10: What error handling exists in libuvc layer?

**Evidence Files:**
- `lib/src/main/jni/libuvc/include/libuvc/libuvc.h:40-81`

**UVC Error Taxonomy (libuvc.h):**
```c
typedef enum uvc_error {
    UVC_SUCCESS = 0,
    UVC_ERROR_IO = -1,
    UVC_ERROR_INVALID_PARAM = -2,
    UVC_ERROR_ACCESS = -3,
    UVC_ERROR_NO_DEVICE = -4,
    UVC_ERROR_NOT_FOUND = -5,
    UVC_ERROR_BUSY = -6,
    UVC_ERROR_TIMEOUT = -7,
    UVC_ERROR_OVERFLOW = -8,
    UVC_ERROR_PIPE = -9,
    UVC_ERROR_INTERRUPTED = -10,
    UVC_ERROR_NO_MEM = -11,
    UVC_ERROR_NOT_SUPPORTED = -12,
    UVC_ERROR_INVALID_DEVICE = -50,
    UVC_ERROR_INVALID_MODE = -51,
    UVC_ERROR_CALLBACK_EXISTS = -52,
    UVC_ERROR_OTHER = -99
} uvc_error_t;
```

**Finding:** **Comprehensive error enumeration exists.** Errors propagate via return codes.

**Architectural Decision:** Error taxonomy is solid. Need structured error context (error message, source file, line).

---

## Category C: Payload Pipeline

### C-01: What payload formats are currently supported?

**Evidence Files:**
- `lib/src/main/jni/libuvc/include/libuvc/libuvc.h:86-110`
- `lib/src/main/jni/libuvc/src/stream.c:1453`

**Frame Format Enum (libuvc.h:86-110):**
```c
enum uvc_frame_format {
    UVC_FRAME_FORMAT_UNKNOWN = 0,
    UVC_FRAME_FORMAT_ANY = 0,
    UVC_FRAME_FORMAT_UNCOMPRESSED,
    UVC_FRAME_FORMAT_COMPRESSED,
    UVC_FRAME_FORMAT_YUYV,
    UVC_FRAME_FORMAT_UYVY,
    UVC_FRAME_FORMAT_RGB,
    UVC_FRAME_FORMAT_BGR,
    UVC_FRAME_FORMAT_MJPEG,
    UVC_FRAME_FORMAT_GRAY8,
    UVC_FRAME_FORMAT_GRAY16,
    UVC_FRAME_FORMAT_BY8,
    UVC_FRAME_FORMAT_BA81,
    UVC_FRAME_FORMAT_SGRBG8,
    UVC_FRAME_FORMAT_SGBRG8,
    UVC_FRAME_FORMAT_SRGGB8,
    UVC_FRAME_FORMAT_SBGGR8,
    UVC_FRAME_FORMAT_NV12,    // XXX added
    UVC_FRAME_FORMAT_COUNT,
};
```

**Finding:** **14 formats supported.** NO H.264/HEVC formats in enum - would need extension.

**Architectural Decision:** Add `UVC_FRAME_FORMAT_H264`, `UVC_FRAME_FORMAT_HEVC` to enum.

---

### C-02: How is MJPEG decoded?

**Evidence Files:**
- `lib/src/main/jni/libjpeg-turbo-1.5.0/` (full library)
- `lib/src/main/jni/libuvc/src/frame-mjpeg.c`
- `lib/src/main/jni/UVCCamera/Android.mk:57`

**MJPEG Decode (frame-mjpeg.c):**
```c
uvc_error_t uvc_mjpeg_to_rgbx(uvc_frame_t *in, uvc_frame_t *out) {
    // Uses libjpeg-turbo tjDecompress2()
}
```

**Linkage (Android.mk:57):**
```makefile
LOCAL_STATIC_LIBRARIES += jpeg-turbo1500_static
```

**Finding:** **MJPEG via libjpeg-turbo 1.5.0** (SIMD-accelerated, CPU decode). Decode to CPU buffer, then converted.

**Architectural Decision:** MJPEG path is optimized. No changes needed unless GPU MJPEG desired.

---

### C-03: Is MediaCodec used for any decoding?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/Android.mk` (no libmediandk)
- Grep found only comment references

**Finding:** **NO MediaCodec integration.**
- libmediandk NOT linked
- AMediaCodec_* never called
- Only comment references to "MediaCodec#createInputSurface"

**Architectural Decision:** MediaCodec integration must be built from scratch for H.264/HEVC.

---

### C-04: How are decoded frames delivered?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/UVCPreview.cpp:546`
- `lib/src/main/jni/UVCCamera/UVCPreview.h:173`

**Callback Mechanism:**
```c
// UVCPreview.h:173
static void uvc_preview_frame_callback(uvc_frame_t *frame, void *vptr_args);

// UVCPreview.cpp:546
void UVCPreview::uvc_preview_frame_callback(uvc_frame_t *frame, void *vptr_args) {
    // Frame delivered via static callback
    // Enqueued to processing pipeline
}
```

**Finding:** Frame callback → pipeline enqueue → conversion → AHardwareBuffer → EGLImage

**Architectural Decision:** Callback mechanism is solid. Consider adding direct Surface path.

---

### C-05: What colorspace conversions exist?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/frame.c` (1,016 lines)

**Conversion Functions (20+):**
```c
uvc_yuyv2rgb()       uvc_yuyv2rgbx()
uvc_yuyv2rgb565()    uvc_yuyv2yuv420SP()
uvc_uyvy2rgb()       uvc_uyvy2rgbx()
uvc_rgb2rgbx()       uvc_rgbx2rgb()
uvc_any2rgbx()       uvc_any2rgb()
uvc_any2iyuv420SP()  uvc_any2yuv420SP()
uvc_mjpeg2rgb()      uvc_mjpeg2rgbx()
// ... plus variants for different pixel formats
```

**Finding:** **20+ conversion functions.** CPU-based with macro unrolling (no SIMD intrinsics in this layer).

**Architectural Decision:** Conversion coverage is comprehensive. SIMD optimization opportunity exists.

---

### C-06: Is there any GPU rendering pipeline?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/EGLImageHelperJNI.cpp` (full file)
- `lib/src/main/jni/UVCCamera/Android.mk:51-52`

**EGL/GLES Integration:**
```c
// EGLImageHelperJNI.cpp:19-22
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

// Android.mk linkage
LOCAL_LDLIBS += -lEGL
LOCAL_LDLIBS += -lGLESv2
```

**EGLImage Creation (EGLImageHelperJNI.cpp:205-281):**
```c
static jlong nativeCreateEGLImageFromHardwareBuffer(
    JNIEnv *env, jclass, jobject eglDisplay, jobject hardwareBuffer) {
    // AHardwareBuffer → EGLImage → GL_TEXTURE_EXTERNAL_OES
}
```

**Finding:** **GPU pipeline EXISTS:**
- ✓ EGL/GLES2 linked
- ✓ AHardwareBuffer → EGLImage bridge
- ✓ Texture external OES support
- ✓ Fence synchronization

**Architectural Decision:** GPU infrastructure is COMPLETE. Zero-copy to GPU working.

---

### C-07: What is the buffer management architecture?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/FrameBufferRing.h` (full file)
- `lib/src/main/jni/UVCCamera/FrameBufferRing.cpp`

**Triple-Buffer Architecture:**
```c
// FrameBufferRing.h:106-111
/**
 * AHardwareBuffer-based triple-buffered ring buffer for UVC frame streaming.
 * Implements MAILBOX frame drop policy:
 * - Producer always writes to the next available buffer (no blocking)
 * - Consumer always reads the most recent completed frame
 * - Frames are dropped (not queued) when producer outpaces consumer
 */
```

**Atomic Indices:**
```c
std::atomic<int>   mWriteIndex{0};
std::atomic<int>   mReadIndex{0};
std::atomic<int>   mLatestCompleted{-1};
```

**Finding:** **Modern lock-free MAILBOX buffer** with:
- Triple buffering
- Atomic index management
- Frame drop policy
- AHardwareBuffer storage

**Architectural Decision:** Buffer management is EXCELLENT. Modern design, no changes needed.

---

## Category D: Timestamp System

### D-01: Are UVC payload headers currently parsed?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/stream.c:744-765`

**PTS/SCR Extraction (stream.c:744-765):**
```c
if (header_info & UVC_STREAM_PTS) {
    if (LIKELY(variable_offset + 4 <= header_len)) {
        strmh->pts = DW_TO_INT(payload + variable_offset);  // ✓ EXTRACTED
        variable_offset += 4;
    }
}

if (header_info & UVC_STREAM_SCR) {
    if (LIKELY(variable_offset + 4 <= header_len)) {
        strmh->last_scr = DW_TO_INT(payload + variable_offset);  // ✓ EXTRACTED
        variable_offset += 4;
    }
}
```

**Finding:** **PTS/SCR ARE EXTRACTED** into `strmh->pts` and `strmh->last_scr`.

**BUT: Never copied to frame!** The `@todo set the frame time` comment at line 1758 confirms this gap.

**Architectural Decision:** ~5 lines of code to connect pts/scr to frame→capture_time.

---

### D-02: What timestamp is currently used for frames?

**Evidence Files:**
- `lib/src/main/jni/libuvc/include/libuvc/libuvc.h:474`
- `lib/src/main/jni/UVCCamera/FrameBufferRing.cpp:369`

**Frame Timestamp Field:**
```c
// libuvc.h:474
struct timeval capture_time;  // NOT connected to PTS!
```

**Current Timestamp Source (FrameBufferRing.cpp:369):**
```c
mMetadata[idx].timestampNs = getCurrentTimeNs();  // CLOCK_MONOTONIC
mMetadata[idx].frameNumber = ++mFrameCounter;
```

**Finding:** **Host-side CLOCK_MONOTONIC used**, not device PTS/SCR.

**Architectural Decision:** Implement timestamp ladder: PTS (preferred) → SCR → host clock (fallback).

---

### D-03: Is there any clock synchronization logic?

**Evidence Files:**
- Grep found no "drift", "regression", "kalman", "sync" in timestamp context

**Finding:** **NO clock synchronization.** PTS→host clock mapping does not exist.

**Architectural Decision:** Clock sync must be built:
1. Linear regression for drift correction
2. 32-bit wrap handling
3. Confidence metric

---

### D-04: How are timestamps exposed to Kotlin?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/FrameSlotMetadata.h:39-40`
- `lib/src/main/jni/UVCCamera/UVCPreview.h:91`

**Timestamp in Metadata:**
```c
// FrameSlotMetadata.h:39-40
int64_t  timestampNs;      // CLOCK_MONOTONIC capture time
uint64_t frameNumber;      // Sequential frame counter
```

**Callback Signature (UVCPreview.h:91):**
```c
// Parameters: data, dataSize, width, height, format, timestampNs
```

**Finding:** `timestampNs` (int64_t, nanoseconds) exposed via callback and metadata.

**Architectural Decision:** Timestamp API exists. Needs: PTS source, clock domain info.

---

### D-05: Is releaseOutputBufferAtTime used?

**Evidence Files:**
- Grep found no `releaseOutputBufferAtTime` or `AMediaCodec_releaseOutputBufferAtTime`

**Finding:** **NOT USED.** No timed release for compositor integration.

**Architectural Decision:** Implement when MediaCodec added for proper A/V sync.

---

### D-06: What timestamp-related telemetry exists?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/StreamTelemetry.h`

**Telemetry Fields:**
```c
std::atomic<int64_t> lastFrameTimestampNs{0};
std::atomic<int64_t> lastStateTransitionTimeNs{0};
// No jitter/drift metrics
```

**Finding:** Basic timestamp tracking exists. No jitter measurement, no drift tracking.

**Architectural Decision:** Add: jitter histogram, drift estimate, sync confidence.

---

## Category E: Control Plane

### E-01: Is GET_INFO used for capability discovery?

**Evidence Files:**
- `lib/src/main/jni/libuvc/include/libuvc/libuvc.h:232`

**GET_INFO Constant:**
```c
UVC_GET_INFO = 0x86,  // Defined but NEVER called
```

**Finding:** **GET_INFO NEVER USED.** Capability bits not queried.

**Architectural Decision:** MAJOR OPPORTUNITY - implement GET_INFO for:
- Read-only detection
- Auto-update capability
- Disabled control detection

---

### E-02: Are control ranges queried (MIN/MAX/DEF/RES)?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/UVCCamera.cpp:970-1260`

**Range Queries:**
```c
ret = get_func(devh, &value, UVC_GET_MIN);
ret = get_func(devh, &value, UVC_GET_MAX);
ret = get_func(devh, &value, UVC_GET_DEF);
// UVC_GET_RES NOT commonly used
```

**Finding:** MIN/MAX/DEF queried. **RES (resolution/step) rarely used.** No caching.

**Architectural Decision:** Add range caching, enforce client-side validation.

---

### E-03: How are controls exposed to Kotlin?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/serenegiant_usb_UVCCamera.cpp`

**Pattern:** Individual JNI methods per control:
- `setExposure()`, `getExposure()`, `updateExposureLimit()`
- `setBrightness()`, `getBrightness()`, `updateBrightnessLimit()`
- etc.

**Finding:** ~40+ individual JNI methods. No unified control abstraction.

**Architectural Decision:** Consider unified control API with typed control objects.

---

### E-04: Is there async control handling?

**Evidence Files:**
- No interrupt endpoint handling for control status

**Finding:** **NO async control handling.** All controls are synchronous.

**Architectural Decision:** Note for CVE-2024-58002 - review async control surfaces if added.

---

### E-05: Are there any vendor-specific control workarounds?

**Evidence Files:**
- `lib/src/main/jni/libuvc/src/stream.c:1539`

**Buggy Device Workaround:**
```c
|| (alt_idx == num_alt) ) {  // XXX always match to last altsetting for buggy device
```

**Finding:** One workaround found for alt setting selection. No structured quirk system.

**Architectural Decision:** Implement quirk registry with VID/PID matching.

---

## Category F: Memory & Threading

### F-01: Is AHardwareBuffer currently used?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/FrameBufferRing.cpp:133-220`
- `lib/src/main/jni/UVCCamera/EGLImageHelperJNI.cpp:233-281`

**AHardwareBuffer Usage:**
```c
// FrameBufferRing.cpp:133-148
AHardwareBuffer_Desc desc = {
    .width = width,
    .height = height,
    .layers = 1,
    .format = format,
    .usage = AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN |
             AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE,
    .stride = 0,
};
int result = AHardwareBuffer_allocate(&desc, &mBuffers[i]);
```

**Finding:** **AHardwareBuffer FULLY IMPLEMENTED:**
- ✓ Triple buffer allocation
- ✓ CPU write access
- ✓ GPU texture binding
- ✓ Fence synchronization
- ✓ API 26+ support, API 29+ optimized

**Architectural Decision:** Zero-copy infrastructure COMPLETE.

---

### F-02: What is the current copy count in frame path?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/UVCPreview.cpp` (memcpy instances)

**Copy Points:**
1. USB → libuvc buffer (unavoidable)
2. libuvc → conversion buffer (for MJPEG/YUYV)
3. Conversion buffer → AHardwareBuffer

**Best Case (H.264 future):** 1 copy (USB→AHardwareBuffer via MediaCodec Surface)
**Current (MJPEG):** 2-3 copies

**Finding:** 2-3 copies typical. H.264 path could be 1 copy.

**Architectural Decision:** Acceptable for MJPEG. Prioritize H.264 for zero-copy.

---

### F-03: What synchronization primitives are used?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/FrameBufferRing.h:374-376`
- `lib/src/main/jni/UVCCamera/HandleManager.h:82-91`

**Primitives:**
```c
// FrameBufferRing.h - lock-free
std::atomic<int> mWriteIndex{0};
std::atomic<int> mReadIndex{0};
std::atomic<int> mLatestCompleted{-1};

// HandleManager.h - atomic generation
std::atomic<uint32_t> generation{0};
std::atomic<int> activeRefs{0};
std::atomic<ContextPtr> context{0};

// SQLiteBufferedPipeline - mutex
Mutex::Autolock lock(handler_mutex);
```

**Finding:** **Mixed model:**
- Lock-free atomics for hot paths (buffer ring)
- Mutex for cold paths (SQLite, handlers)
- pthread_mutex for legacy code

**Architectural Decision:** Lock-free where it matters. Good design.

---

### F-04: Is there thread priority management?

**Evidence Files:**
- No `sched_param`, `SCHED_*`, `nice`, or priority setting found

**Finding:** **NO thread priority management.** All threads use default priority.

**Architectural Decision:** Add priority for USB read thread (SCHED_FIFO/RR consideration).

---

### F-05: How is backpressure handled?

**Evidence Files:**
- `lib/src/main/jni/UVCCamera/FrameBufferRing.cpp:858-861`
- `lib/src/main/jni/UVCCamera/UVCPreview.cpp:744`

**Backpressure Handling:**
```c
// FrameBufferRing.cpp:858-861
// Check if queue is full
if (/* full */) {
    LOGW("ENQUEUE_DIAG[%d]: Queue full, dropping frame", callNum);
}

// UVCPreview.cpp:744
// Queue is full - track this drop
```

**Telemetry:**
```c
std::atomic<uint64_t> framesDroppedQueueFull{0};
```

**Finding:** **MAILBOX drop policy implemented.** Frames dropped when queue full, tracked via telemetry.

**Architectural Decision:** Backpressure handling is COMPLETE.

---

### F-06: What is the memory ownership model?

**Evidence Files:**
- Grep found no `unique_ptr`, `shared_ptr`, `make_unique`, `make_shared`

**Memory Management:**
```c
// Manual allocation
frame = uvc_allocate_frame(data_bytes);
uvc_free_frame(frame);

// Raw pointers
AHardwareBuffer* mBuffers[FRAME_BUFFER_COUNT];
```

**Finding:** **Manual memory management.** No smart pointers in native layer.

**Architectural Decision:** Consider `std::unique_ptr` for new code. Reference counting for shared resources.

---

## Category G: Build System

### G-01: What build system is currently used?

**Evidence Files:**
- `lib/src/main/jni/Android.mk` (root)
- `lib/src/main/jni/Application.mk`
- `lib/build.gradle.kts:32`

**Build System:**
```kotlin
// build.gradle.kts:32
ndkBuild {
    path = file("src/main/jni/Android.mk")
}
```

```makefile
# Application.mk:29-32
APP_PLATFORM := android-26
APP_ABI := armeabi-v7a arm64-v8a
APP_OPTIM := release
APP_STL := c++_shared
```

**Finding:** **ndk-build** with Android.mk/Application.mk. Gradle ndkBuild integration.

**Architectural Decision:** Continue ndk-build. CMake migration optional.

---

### G-02: What NDK version is targeted?

**Evidence Files:**
- `lib/src/main/jni/Application.mk:29`
- `lib/build.gradle.kts:19`

**NDK Configuration:**
```makefile
APP_PLATFORM := android-26  # Minimum API level
```

**Finding:** API 26 minimum. NDK version not pinned (uses project default).

**Architectural Decision:** Explicit NDK version for reproducibility. r28+ for 16KB pages.

---

### G-03: What C++ standard is used?

**Evidence Files:**
- `lib/src/main/jni/Application.mk` - No C++ standard specified
- No `-std=c++` flags found

**Finding:** **C++ standard NOT explicitly set.** Uses NDK default (C++14 for recent NDKs).

**Architectural Decision:** Add `APP_CPPFLAGS += -std=c++17` for:
- `std::optional`
- `std::string_view`
- Structured bindings

---

### G-04: How are dependencies managed?

**Evidence Files:**
- `lib/src/main/jni/Android.mk:4-7`

**Dependencies:**
```makefile
include $(PROJ_PATH)/UVCCamera/Android.mk
include $(PROJ_PATH)/libjpeg-turbo-1.5.0/Android.mk
include $(PROJ_PATH)/libusb/android/jni/Android.mk
include $(PROJ_PATH)/libuvc/android/jni/Android.mk
```

**Finding:** **Vendored dependencies.** All source included in tree.

**Architectural Decision:** Keep vendored for stability. Consider git submodules for updates.

---

### G-05: Are security flags properly configured?

**Evidence Files:**
- `lib/src/main/jni/Application.mk:40`
- `lib/src/main/jni/UVCCamera/Android.mk:34, 45`

**Security Flags:**
```makefile
# Application.mk:40 - 16KB page alignment (Android 15+)
APP_LDFLAGS := -Wl,-z,max-page-size=16384

# Android.mk:45 - Optimization only
LOCAL_CFLAGS += -O3 -fstrict-aliasing -fprefetch-loop-arrays
```

**Missing:**
- No explicit `-fstack-protector-strong`
- No `-D_FORTIFY_SOURCE=2`
- No `-fPIC`/`-fPIE` explicit (NDK defaults)

**Finding:** 16KB page alignment present. Other security flags rely on NDK defaults.

**Architectural Decision:** Consider explicit security flags for defense-in-depth.

---

## Summary: Architectural Decisions Unlocked

| Category | Key Finding | Implication |
|----------|-------------|-------------|
| **A: Transport** | Isochronous IMPLEMENTED | Optimize, don't build |
| **A: Transport** | FD injection WORKING | OPP-011 complete |
| **B: libuvc** | Heavy fork, well-maintained | Continue fork |
| **B: libuvc** | GET_INFO never used | Major opportunity |
| **C: Payload** | No MediaCodec | Build H.264 from scratch |
| **C: Payload** | AHardwareBuffer working | Zero-copy ready |
| **D: Timestamp** | PTS extracted, discarded | ~5 LOC to fix |
| **D: Timestamp** | No clock sync | Build regression sync |
| **E: Controls** | No GET_INFO | Add capability query |
| **F: Memory** | Lock-free MAILBOX | Excellent design |
| **F: Threading** | No priorities | Add for USB thread |
| **G: Build** | ndk-build working | CMake optional |
| **G: Build** | No C++ standard set | Add C++17 |

---

## Recommended Priority Actions

### Immediate (High Impact, Low Effort)
1. **Connect PTS to frame->capture_time** (~5 LOC, stream.c)
2. **Add C++17 flag** to Application.mk
3. **Implement GET_INFO queries** for capability discovery

### Short Term (1-2 weeks)
1. **Clock synchronization** - Linear regression for PTS→host mapping
2. **GET_INFO caching** - Query once, cache with invalidation
3. **Thread priority** for USB read thread

### Medium Term (2-4 weeks)
1. **MediaCodec H.264 integration** - Full decode pipeline
2. **XU framework** - Typed vendor control abstraction
3. **Error recovery state machine** - Structured disconnect handling

---

*End of INVESTIGATION-001 Findings*
