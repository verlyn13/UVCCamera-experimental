# INVENTORY-003: Header Analysis

**Audit:** AUDIT-001 UVCCamera Codebase Reconnaissance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Summary Statistics

| Metric | Value |
|--------|-------|
| Total Headers | 156 |
| Public Headers (in `include/`) | 48 |
| Internal Headers | 108 |
| Unique Includes Referenced | ~200 |

---

## Header Classification

### Public API Headers (Critical)

These headers define the public interfaces consumers depend on:

| Header | Component | Purpose |
|--------|-----------|---------|
| `libuvc/include/libuvc/libuvc.h` | libuvc | **Main UVC API** - Device/stream management |
| `libuvc/include/libuvc/libuvc_internal.h` | libuvc | Internal UVC structures |
| `libusb/libusb/libusb.h` | libusb | **Main USB API** - Device access |
| `libjpeg-turbo-1.5.0/jpeglib.h` | libjpeg | **Main JPEG API** - Compression/decompression |
| `libjpeg-turbo-1.5.0/turbojpeg.h` | libjpeg | TurboJPEG high-level API |
| `rapidjson/include/rapidjson/document.h` | rapidjson | JSON DOM API |
| `rapidjson/include/rapidjson/reader.h` | rapidjson | JSON SAX API |

### Internal Headers (UVCCamera Core)

| Header | Lines | Purpose |
|--------|-------|---------|
| `UVCCamera/UVCCamera.h` | 430 | Main camera class definition |
| `UVCCamera/UVCPreview.h` | 414 | Preview/conversion thread |
| `UVCCamera/FrameBufferRing.h` | ~400 | AHardwareBuffer ring buffer |
| `UVCCamera/HandleManager.h` | ~370 | Slot-based JNI handle safety |
| `UVCCamera/StreamTelemetry.h` | ~710 | Telemetry (37 metrics) |
| `UVCCamera/Parameters.h` | ~200 | Camera parameter management |
| `UVCCamera/OutputMode.h` | ~117 | Frame routing enum |
| `UVCCamera/FrameSlotMetadata.h` | ~100 | Per-frame metadata |
| `UVCCamera/LayoutContract.h` | ~80 | ABI validation |
| `UVCCamera/libUVCCamera.h` | ~50 | Library exports |
| `utilbase.h` | 230 | Utility macros, logging |
| `localdefines.h` | 75 | Local preprocessor definitions |

### Pipeline Headers

| Header | Purpose |
|--------|---------|
| `pipeline/IPipeline.h` | Abstract pipeline interface |
| `pipeline/AbstractBufferedPipeline.h` | Buffering framework |
| `pipeline/SimpleBufferedPipeline.h` | Simple buffer impl |
| `pipeline/SQLiteBufferedPipeline.h` | SQLite-backed storage |
| `pipeline/CallbackPipeline.h` | Callback-driven pipeline |
| `pipeline/PreviewPipeline.h` | Display preview |
| `pipeline/PublisherPipeline.h` | Event publishing |
| `pipeline/ConvertPipeline.h` | Format conversion |
| `pipeline/DistributePipeline.h` | Frame distribution |
| `pipeline/CaptureBasePipeline.h` | Capture base class |
| `pipeline/pipeline_helper.h` | Pipeline utilities |

---

## Include Frequency Analysis

### Most Frequently Included (Top 30)

| Count | Header | Category |
|-------|--------|----------|
| 65 | `stdlib.h` | System |
| 60 | `stdio.h` | System |
| 59 | `jpeglib.h` | Dependency (JPEG) |
| 57 | `jinclude.h` | Dependency (JPEG) |
| 50 | `string.h` | System |
| 37 | `errno.h` | System |
| 27 | `utilbase.h` | Internal (logging) |
| 27 | `unistd.h` | System (POSIX) |
| 27 | `libusbi.h` | Dependency (USB internal) |
| 22 | `libusb.h` | Dependency (USB API) |
| 21 | `sys/types.h` | System |
| 21 | `libUVCCamera.h` | Internal |
| 21 | `config.h` | Configuration |
| 20 | `assert.h` | System |
| 19 | `fcntl.h` | System (POSIX) |
| 19 | `ctype.h` | System |
| 18 | `stdint.h` | System |
| 18 | `cdjpeg.h` | Dependency (JPEG) |
| 16 | `libuvc/libuvc.h` | Dependency (UVC API) |
| 15 | `libuvc/libuvc_internal.h` | Dependency (UVC) |
| 15 | `jsimd.h` | Dependency (JPEG SIMD) |
| 13 | `pthread.h` | System (threading) |
| 13 | `jni.h` | Platform (Android JNI) |
| 11 | `rapidjson.h` | Dependency (JSON) |
| 11 | `jsimd_altivec.h` | Dependency (PowerPC SIMD) |
| 10 | `time.h` | System |
| 10 | `sys/time.h` | System |
| 10 | `stdarg.h` | System |
| 10 | `jpegcomp.h` | Dependency (JPEG) |
| 10 | `jerror.h` | Dependency (JPEG) |

### Header Category Distribution

| Category | Count | Examples |
|----------|-------|----------|
| **System** | ~25 | `stdlib.h`, `stdio.h`, `string.h`, `errno.h` |
| **POSIX** | ~10 | `unistd.h`, `pthread.h`, `fcntl.h`, `sys/time.h` |
| **Platform** | 3 | `jni.h`, `android/log.h`, `android/hardware_buffer.h` |
| **libjpeg** | ~15 | `jpeglib.h`, `jinclude.h`, `turbojpeg.h` |
| **libusb** | ~5 | `libusb.h`, `libusbi.h` |
| **libuvc** | ~5 | `libuvc.h`, `libuvc_internal.h` |
| **rapidjson** | ~10 | `rapidjson.h`, `document.h`, `reader.h` |
| **Internal** | ~20 | `utilbase.h`, `libUVCCamera.h`, `OutputMode.h` |

---

## Critical Header Dependencies

### UVCCamera Core Dependencies

```
UVCCamera.cpp
├── jni.h                    (Platform - JNI)
├── android/log.h            (Platform - logging)
├── libUVCCamera.h           (Internal)
├── utilbase.h               (Internal - macros)
├── UVCCamera.h              (Internal)
├── UVCPreview.h             (Internal)
├── libuvc/libuvc.h          (Dependency - UVC)
├── HandleManager.h          (Internal - safety)
└── StreamTelemetry.h        (Internal - metrics)

FrameBufferRing.cpp
├── FrameBufferRing.h        (Internal)
├── android/hardware_buffer.h (Platform - AHardwareBuffer)
├── StreamTelemetry.h        (Internal - metrics)
├── FrameSlotMetadata.h      (Internal)
├── turbojpeg.h              (Dependency - JPEG for captureToFd)
└── atomic                   (C++ Standard)
```

### libuvc Dependencies

```
libuvc/src/*.c
├── libuvc/libuvc.h          (Public API)
├── libuvc/libuvc_internal.h (Internal)
├── libusb.h                 (Dependency - USB)
├── jpeglib.h                (Dependency - MJPEG decode)
└── utlist.h                 (Utility - linked list)
```

---

## Macro Definitions Inventory

### Key Macros in utilbase.h

| Macro | Purpose |
|-------|---------|
| `LOGD`, `LOGI`, `LOGW`, `LOGE` | Android logging wrappers |
| `SAFE_FREE(p)` | Safe memory free with null check |
| `SAFE_DELETE(p)` | Safe C++ delete with null check |
| `ENTER()`, `EXIT()`, `RETURN()` | Debug trace macros |
| `CHECK(cond, msg)` | Assert with logging |
| `MARK(msg)` | Debug marker |

### Key Macros in localdefines.h

| Macro | Value | Purpose |
|-------|-------|---------|
| `LOCAL_DEBUG` | 0/1 | Enable debug logging |
| `ACCESS_RAW_DESCRIPTORS` | defined | Enable raw USB descriptor access |

### Key Macros in OutputMode.h

| Enum Value | Purpose |
|------------|---------|
| `OutputMode::IDLE` | WARM state - capture only |
| `OutputMode::DIRECT_WINDOW` | Legacy ANativeWindow path |
| `OutputMode::RING_BUFFER` | Modern GPU-integrated path |

---

## Extern "C" Declarations

Headers with C linkage for JNI compatibility:

| Header | Extern "C" Block |
|--------|------------------|
| `_onload.h` | JNI registration functions |
| `libusb.h` | Full USB API |
| `libuvc.h` | Full UVC API |
| `turbojpeg.h` | TurboJPEG API |

---

## Header Organization Patterns

### Separation of Concerns

1. **Public vs Internal**: libuvc/libusb use `include/` for public, source-adjacent for internal
2. **Original Preservation**: `*_original.h` files preserve upstream versions
3. **Platform Abstraction**: `libusb/os/*.h` for OS-specific implementations

### Include Guard Patterns

| Pattern | Example | Component |
|---------|---------|-----------|
| `_HEADER_H_` | `_ONLOAD_H_` | UVCCamera |
| `HEADER_H_` | `UTILBASE_H_` | UVCCamera |
| `LIBUVC_*` | `LIBUVC_H` | libuvc |
| `LIBUSBI_H` | `LIBUSBI_H` | libusb |

---

## Raw Data

- Full public headers list: `raw/public-headers.txt`
- Include frequency analysis: `raw/include-frequency.txt`

---

*End of INVENTORY-003*
