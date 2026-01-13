# BUILD-001: Android.mk Inventory

**Audit:** AUDIT-005 Build System Archaeology
**Generated:** 2026-01-11
**Target:** ndk-build Configuration Analysis

---

## Summary

| Metric | Count |
|--------|-------|
| Android.mk files | 5 |
| Application.mk files | 2 |
| Additional .mk files | 5 |
| Total .mk files | 12 |
| Build modules (LOCAL_MODULE) | 8 active + 8 example/test |
| Static libraries | 4 |
| Shared libraries | 4 |

---

## 1. Android.mk File Hierarchy

### Root Orchestrator
**File:** `jni/Android.mk`

```makefile
PROJ_PATH := $(call my-dir)
include $(CLEAR_VARS)
include $(PROJ_PATH)/UVCCamera/Android.mk
include $(PROJ_PATH)/libjpeg-turbo-1.5.0/Android.mk
include $(PROJ_PATH)/libusb/android/jni/Android.mk
include $(PROJ_PATH)/libuvc/android/jni/Android.mk
```

**Analysis:**
- Central include orchestrator
- Build order is significant (dependencies build first)
- No actual module definitions in root file

### Include Tree

```
jni/Android.mk (root)
├── jni/UVCCamera/Android.mk
│   └── UVCCamera (SHARED_LIBRARY)
├── jni/libjpeg-turbo-1.5.0/Android.mk
│   ├── jpeg-turbo1500_static (STATIC_LIBRARY)
│   └── jpeg-turbo1500 (SHARED_LIBRARY)
├── jni/libusb/android/jni/Android.mk
│   └── jni/libusb/android/jni/libusb.mk
│       ├── libusb100_static (STATIC_LIBRARY)
│       └── libusb100 (SHARED_LIBRARY) [aliased as usb100]
└── jni/libuvc/android/jni/Android.mk
    ├── libuvc_static (STATIC_LIBRARY)
    └── uvc (SHARED_LIBRARY)
```

---

## 2. Module Definitions

### Active Modules (8 total)

| Module Name | Type | File | Dependencies |
|-------------|------|------|--------------|
| `UVCCamera` | SHARED | UVCCamera/Android.mk:77 | usb100, uvc, jpeg-turbo1500_static |
| `jpeg-turbo1500_static` | STATIC | libjpeg-turbo-1.5.0/Android.mk:33 | none |
| `jpeg-turbo1500` | SHARED | libjpeg-turbo-1.5.0/Android.mk:266 | jpeg-turbo1500_static |
| `libusb100_static` | STATIC | libusb/android/jni/libusb.mk:63 | none |
| `libusb100` | SHARED | libusb/android/jni/libusb.mk:75 | libusb100_static |
| `libuvc_static` | STATIC | libuvc/android/jni/Android.mk:73 | jpeg-turbo1500, usb100 |
| `uvc` | SHARED | libuvc/android/jni/Android.mk:86 | libuvc_static |

### Module Naming Discrepancy

**CRITICAL:** `LOCAL_MODULE := libusb100` generates `libusb100.so` but is referenced as `usb100`:

```makefile
# In libusb.mk:75
LOCAL_MODULE := libusb100

# In UVCCamera/Android.mk:54
LOCAL_SHARED_LIBRARIES += usb100 uvc
```

**Evidence:** ndk-build automatically strips `lib` prefix, but this can cause confusion. The shared library loads as `libusb100.so` at runtime.

### Example/Test Modules (disabled, 8 total)

| Module | File | Notes |
|--------|------|-------|
| `testlib` | libusb/android/jni/tests.mk:36 | Not included |
| `stress` | libusb/android/jni/tests.mk:54 | Not included |
| `listdevs` | libusb/android/jni/examples.mk:35 | Not included |
| `xusb` | libusb/android/jni/examples.mk:51 | Not included |
| `hotplugtest` | libusb/android/jni/examples.mk:67 | Not included |
| `fxload` | libusb/android/jni/examples.mk:84 | Not included |
| `sam3u_benchmark` | libusb/android/jni/examples.mk:100 | Not included |
| `dpfp` / `dpfp_threaded` | libusb/android/jni/examples.mk | Not included |

---

## 3. Source File Counts Per Module

### UVCCamera
```makefile
LOCAL_SRC_FILES := \
    _onload.cpp \
    utilbase.cpp \
    HandleManager.cpp \
    UVCCamera.cpp \
    UVCPreview.cpp \
    UVCButtonCallback.cpp \
    UVCStatusCallback.cpp \
    UVCReadinessCallback.cpp \
    Parameters.cpp \
    FrameBufferRing.cpp \
    FrameBufferJNI.cpp \
    LayoutContract.cpp \
    EGLImageHelperJNI.cpp \
    serenegiant_usb_UVCCamera.cpp
```
**Count:** 14 C++ source files

### libjpeg-turbo1500
**Count:** ~45+ C source files + SIMD assembly (varies by ABI)
- Core: 38 .c files
- Turbo extensions: 4 .c files
- SIMD (arm64): 2 files (jsimd_arm64.c, jsimd_arm64_neon.S)
- SIMD (x86_64): 17 .asm files
- SIMD (x86): 28 .asm files

### libusb100
```makefile
LOCAL_SRC_FILES := \
    libusb/core.c \
    libusb/descriptor.c \
    libusb/hotplug.c \
    libusb/io.c \
    libusb/sync.c \
    libusb/strerror.c \
    libusb/os/android_usbfs.c \
    libusb/os/poll_posix.c \
    libusb/os/threads_posix.c \
    libusb/os/android_netlink.c
```
**Count:** 10 C source files
**Note:** `android_usbfs.c` and `android_netlink.c` are Android-specific modifications of Linux versions

### libuvc
```makefile
LOCAL_SRC_FILES := \
    src/ctrl.c \
    src/device.c \
    src/diag.c \
    src/frame.c \
    src/frame-mjpeg.c \
    src/init.c \
    src/stream.c
```
**Count:** 7 C source files

---

## 4. Include Paths

### UVCCamera
```makefile
LOCAL_C_INCLUDES := \
    $(LOCAL_PATH)/ \
    $(LOCAL_PATH)/../ \
    $(LOCAL_PATH)/../rapidjson/include \
```

### libjpeg-turbo1500
```makefile
LOCAL_C_INCLUDES := \
    $(LOCAL_PATH)/ \
    $(LOCAL_PATH)/include \
    $(LOCAL_PATH)/simd \
```

### libusb100
```makefile
LOCAL_C_INCLUDES += \
    $(LOCAL_PATH)/ \
    $(LOCAL_PATH)/libusb \
    $(LOCAL_PATH)/libusb/os \
    $(LOCAL_PATH)/../ \
    $(LOCAL_PATH)/../include \
    $(LOCAL_PATH)/android \
```

### libuvc
```makefile
LOCAL_C_INCLUDES += \
    $(LOCAL_PATH)/.. \
    $(LOCAL_PATH)/include \
    $(LOCAL_PATH)/include/libuvc
```

---

## 5. Original vs Modified Files

### libusb Modifications

**Original:** `libusb/android/jni/Android_original.mk`
- Includes: libusb.mk, examples.mk, tests.mk

**Current:** `libusb/android/jni/Android.mk`
- Includes: libusb.mk only (examples/tests disabled)

**Original:** `libusb/android/jni/libusb_original.mk`
- Module: `libusb1.0` (standard name)
- No optimization flags
- Simple shared library build

**Current:** `libusb/android/jni/libusb.mk`
- Module: `libusb100` (renamed)
- Added static library intermediate
- Added optimization flags: `-O3 -fstrict-aliasing -fprefetch-loop-arrays`
- Added: `-DACCESS_RAW_DESCRIPTORS`

### Modification Summary

| Change | Original | Modified | Impact |
|--------|----------|----------|--------|
| Module name | libusb1.0 | libusb100 | Binary naming |
| Build type | Shared only | Static + Shared | Flexibility |
| Optimization | None | -O3 | Performance |
| ACCESS_RAW_DESCRIPTORS | Not set | Defined | USB descriptor access |

---

## 6. Dependency Matrix

```
                 jpeg-turbo1500  usb100  uvc  nativewindow  EGL  GLESv2  log  android
UVCCamera             S           S      S        S         S      S     S      S
uvc                   S           S      -        -         -      -     S      -
libusb100             -           -      -        -         -      -     S      -
jpeg-turbo1500        -           -      -        -         -      -     -      -

Legend: S = Shared library dependency, - = No dependency
```

### System Library Dependencies

| Module | System Libraries |
|--------|------------------|
| UVCCamera | -landroid -llog -lnativewindow -lEGL -lGLESv2 |
| libuvc | -llog |
| libusb | -llog |
| libjpeg-turbo | -ldl |

---

## 7. Build Order

Based on dependency analysis, the effective build order is:

1. **libjpeg-turbo1500_static** → **jpeg-turbo1500** (no deps)
2. **libusb100_static** → **libusb100** (no deps)
3. **libuvc_static** → **uvc** (requires jpeg-turbo1500, usb100)
4. **UVCCamera** (requires all above)

---

## 8. File Inventory

| File Path | Purpose | Lines |
|-----------|---------|-------|
| `jni/Android.mk` | Root orchestrator | 7 |
| `jni/Application.mk` | Global build settings | 41 |
| `jni/UVCCamera/Android.mk` | Main library module | 79 |
| `jni/libjpeg-turbo-1.5.0/Android.mk` | JPEG library | 269 |
| `jni/libusb/android/jni/Android.mk` | USB stub (includes libusb.mk) | 24 |
| `jni/libusb/android/jni/libusb.mk` | USB library module | 77 |
| `jni/libusb/android/jni/Application.mk` | USB-specific (unused) | 25 |
| `jni/libuvc/android/jni/Android.mk` | UVC library module | 88 |
| `jni/libusb/android/jni/Android_original.mk` | Original (reference) | 24 |
| `jni/libusb/android/jni/libusb_original.mk` | Original (reference) | 61 |
| `jni/libusb/android/jni/examples.mk` | Examples (disabled) | ~140 |
| `jni/libusb/android/jni/tests.mk` | Tests (disabled) | ~60 |

---

## 9. Findings Summary

### Issues Identified

| ID | Severity | Issue | Location |
|----|----------|-------|----------|
| MK-001 | Low | Module name inconsistency (libusb100 vs usb100) | libusb.mk |
| MK-002 | Info | Disabled example/test builds | libusb Android.mk |
| MK-003 | Info | Original files retained alongside modified | libusb directory |
| MK-004 | Medium | MIPS references in libjpeg-turbo (deprecated ABI) | libjpeg-turbo Android.mk |

### Positive Findings

| ID | Finding | Location |
|----|---------|----------|
| MK-P01 | Proper static/shared library separation | All modules |
| MK-P02 | EXPORT_C_INCLUDES used correctly | All modules |
| MK-P03 | ABI-specific SIMD optimizations | libjpeg-turbo |
| MK-P04 | Build order follows dependencies | Root Android.mk |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **BUILD-002** | Application.mk configuration |
| **BUILD-003** | Compiler flag extraction |
| **BUILD-004** | Dependency graph construction |
| **INVENTORY-004** | Original build config analysis |

---

*End of BUILD-001*
