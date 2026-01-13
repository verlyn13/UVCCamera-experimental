# INVENTORY-004: Build Configuration

**Audit:** AUDIT-001 UVCCamera Codebase Reconnaissance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Summary

| Metric | Value |
|--------|-------|
| Build System | Android NDK (ndk-build) |
| Total Android.mk Files | 6 |
| Shared Libraries Built | 4 (libUVCCamera, uvc, usb100, jpeg-turbo1500) |
| Static Libraries Built | 3 (libuvc_static, libusb100_static, jpeg-turbo1500_static) |
| Target ABIs | armeabi-v7a, arm64-v8a |
| Min API Level | 26 (Android 8.0) |

---

## Application.mk (NDK Configuration)

**Path:** `jni/Application.mk`

| Setting | Value | Notes |
|---------|-------|-------|
| `APP_PLATFORM` | android-26 | Android 8.0 minimum |
| `APP_ABI` | armeabi-v7a arm64-v8a | 32-bit and 64-bit ARM |
| `APP_OPTIM` | release | Optimized build |
| `APP_STL` | c++_shared | Shared C++ runtime (required for std::mutex) |
| `APP_LDFLAGS` | `-Wl,-z,max-page-size=16384` | 16KB page alignment for Android 15+ |

### Modern Adaptations
- **16KB Page Size:** Added for Android 15+ compatibility (2024 requirement)
- **c++_shared STL:** Required for C++11 threading primitives in WARM state handshake

---

## Root Android.mk (Orchestration)

**Path:** `jni/Android.mk`

```makefile
PROJ_PATH := $(call my-dir)
include $(CLEAR_VARS)
include $(PROJ_PATH)/UVCCamera/Android.mk
include $(PROJ_PATH)/libjpeg-turbo-1.5.0/Android.mk
include $(PROJ_PATH)/libusb/android/jni/Android.mk
include $(PROJ_PATH)/libuvc/android/jni/Android.mk
```

### Build Order
1. UVCCamera/Android.mk
2. libjpeg-turbo-1.5.0/Android.mk
3. libusb/android/jni/Android.mk
4. libuvc/android/jni/Android.mk

---

## Module: libUVCCamera.so

**Path:** `jni/UVCCamera/Android.mk`

### Build Configuration

| Setting | Value |
|---------|-------|
| `LOCAL_MODULE` | UVCCamera |
| `LOCAL_ARM_MODE` | arm |
| Build Type | Shared library (.so) |

### Source Files (15 files)

```
_onload.cpp           - JNI registration
utilbase.cpp          - Utility functions
HandleManager.cpp     - JNI handle management
UVCCamera.cpp         - Main camera implementation (~2900 lines)
UVCPreview.cpp        - Preview/conversion (~3000 lines)
UVCButtonCallback.cpp - Button events
UVCStatusCallback.cpp - Status events
UVCReadinessCallback.cpp - Readiness events
Parameters.cpp        - Camera parameters
FrameBufferRing.cpp   - AHardwareBuffer ring buffer
FrameBufferJNI.cpp    - JNI frame buffer bindings
LayoutContract.cpp    - ABI validation
EGLImageHelperJNI.cpp - EGL integration
serenegiant_usb_UVCCamera.cpp - JNI entry point
```

### Include Paths

| Path | Purpose |
|------|---------|
| `$(LOCAL_PATH)/` | UVCCamera headers |
| `$(LOCAL_PATH)/../` | Root jni directory |
| `$(LOCAL_PATH)/../rapidjson/include` | JSON parsing |

### Compiler Flags

| Flag | Purpose |
|------|---------|
| `-DANDROID_NDK` | Android platform indicator |
| `-DLOG_NDEBUG` | Disable debug logging |
| `-DACCESS_RAW_DESCRIPTORS` | Enable raw USB descriptor access |
| `-O3` | Maximum optimization |
| `-fstrict-aliasing` | Strict aliasing optimization |
| `-fprefetch-loop-arrays` | Array prefetch optimization |

### Link Dependencies

| Library | Type | Purpose |
|---------|------|---------|
| `-llog` | System | Android logging |
| `-landroid` | System | Android native APIs |
| `-lnativewindow` | System | ANativeWindow |
| `-lEGL` | System | EGL graphics |
| `-lGLESv2` | System | OpenGL ES 2.0 |
| `usb100` | Shared | libusb |
| `uvc` | Shared | libuvc |
| `jpeg-turbo1500_static` | Static | JPEG encoding |

---

## Module: libusb (usb100)

**Path:** `jni/libusb/android/jni/libusb.mk`

### Build Configuration

| Setting | Static | Shared |
|---------|--------|--------|
| `LOCAL_MODULE` | libusb100_static | usb100 |
| Build Type | .a | .so |

### Source Files (10 files)

```
libusb/core.c           - Core USB operations
libusb/descriptor.c     - USB descriptor parsing
libusb/hotplug.c        - Hotplug event handling
libusb/io.c             - I/O operations
libusb/sync.c           - Synchronous operations
libusb/strerror.c       - Error string handling
libusb/os/android_usbfs.c   - Android USB filesystem (modified)
libusb/os/poll_posix.c      - POSIX polling
libusb/os/threads_posix.c   - POSIX threading
libusb/os/android_netlink.c - Android netlink (modified)
```

### Android Modifications
- `linux_usbfs.c` → `android_usbfs.c` (Android-specific USB filesystem)
- `linux_netlink.c` → `android_netlink.c` (Android-specific netlink)

### Compiler Flags

| Flag | Purpose |
|------|---------|
| `-DANDROID_NDK` | Platform indicator |
| `-DLOG_NDEBUG` | Disable debug logging |
| `-DACCESS_RAW_DESCRIPTORS` | Raw USB descriptor access |
| `-O3` | Maximum optimization |

### License
**LGPL v2.1** - Different from main project (Apache 2.0)

---

## Module: libuvc (uvc)

**Path:** `jni/libuvc/android/jni/Android.mk`

### Build Configuration

| Setting | Static | Shared |
|---------|--------|--------|
| `LOCAL_MODULE` | libuvc_static | uvc |
| Build Type | .a | .so |

### Source Files (7 files)

```
src/ctrl.c       - Control transfers
src/device.c     - Device management
src/diag.c       - Diagnostics
src/frame.c      - Frame handling
src/frame-mjpeg.c - MJPEG frame decoding
src/init.c       - Initialization
src/stream.c     - Streaming
```

### Compiler Flags

| Flag | Purpose |
|------|---------|
| `-DANDROID_NDK` | Platform indicator |
| `-DLOG_NDEBUG` | Disable debug logging |
| `-DUVC_DEBUGGING` | Enable UVC debug features |

### Dependencies

| Library | Type | Purpose |
|---------|------|---------|
| `jpeg-turbo1500` | Shared | MJPEG decoding |
| `usb100` | Shared | USB transport |

### License
**BSD** - Different from main project

---

## Module: libjpeg-turbo (jpeg-turbo1500)

**Path:** `jni/libjpeg-turbo-1.5.0/Android.mk`

### Build Configuration

| Setting | Static | Shared |
|---------|--------|--------|
| `LOCAL_MODULE` | jpeg-turbo1500_static | jpeg-turbo1500 |
| Build Type | .a | .so |
| Version | 1.5.0 | |

### Source Files

#### Core JPEG (40 files)
```
jcapimin.c  jcapistd.c  jccoefct.c  jccolor.c   jcdctmgr.c
jchuff.c    jcinit.c    jcmainct.c  jcmarker.c  jcmaster.c
jcomapi.c   jcparam.c   jcphuff.c   jcprepct.c  jcsample.c
jctrans.c   jdapimin.c  jdapistd.c  jdatadst.c  jdatasrc.c
jdcoefct.c  jdcolor.c   jddctmgr.c  jdhuff.c    jdinput.c
jdmainct.c  jdmarker.c  jdmaster.c  jdmerge.c   jdphuff.c
jdpostct.c  jdsample.c  jdtrans.c   jerror.c    jfdctflt.c
jfdctfst.c  jfdctint.c  jidctflt.c  jidctfst.c  jidctint.c
jidctred.c  jquant1.c   jquant2.c   jutils.c    jmemmgr.c
jmemnobs.c
```

#### Arithmetic Coding (3 files)
```
jaricom.c  jcarith.c  jdarith.c
```

#### TurboJPEG API (4 files)
```
turbojpeg.c      transupp.c
jdatadst-tj.c    jdatasrc-tj.c
```

### Architecture-Specific SIMD

| ABI | SIMD Source | Notes |
|-----|-------------|-------|
| `armeabi` | `jsimd_arm.c` + `jsimd_arm_neon.S` | NEON (optional) |
| `armeabi-v7a` | `jsimd_arm.c` + `jsimd_arm_neon.S` | NEON (optional) |
| `arm64-v8a` | `jsimd_arm64.c` + `jsimd_arm64_neon.S` | NEON (optional) |
| `x86_64` | `jsimd_x86_64.c` + 15 `.asm` files | SSE2 |
| `x86` | `jsimd_i386.c` + 32 `.asm` files | MMX/SSE/SSE2/3DNow |
| `mips` | `jsimd_mips.c` + DSPR2 or none | MSA not supported in Clang |
| Other | `jsimd_none.c` | No SIMD |

### Size Configuration

| ABI | `SIZEOF_SIZE_T` |
|-----|-----------------|
| 32-bit (armeabi, armeabi-v7a, x86, mips) | 4 |
| 64-bit (arm64-v8a, x86_64) | 8 |

### License
**BSD-style IJG License** + **Modified BSD** for TurboJPEG

---

## Build Output Matrix

| Module | Static | Shared | Dependencies |
|--------|--------|--------|--------------|
| jpeg-turbo1500 | ✅ jpeg-turbo1500_static.a | ✅ jpeg-turbo1500.so | (none) |
| usb100 | ✅ libusb100_static.a | ✅ usb100.so | log |
| uvc | ✅ libuvc_static.a | ✅ uvc.so | jpeg-turbo1500, usb100, log |
| UVCCamera | ❌ | ✅ libUVCCamera.so | uvc, usb100, jpeg-turbo1500_static, system libs |

### Dependency Graph

```
libUVCCamera.so
├── libuvc.so (uvc)
│   ├── libjpeg-turbo1500.so
│   └── libusb100.so (usb100)
├── libusb100.so (usb100)
├── libjpeg-turbo1500_static.a (linked statically)
└── System Libraries
    ├── log
    ├── android
    ├── nativewindow
    ├── EGL
    └── GLESv2
```

---

## Compiler Flag Summary

### Common Flags (All Modules)

| Flag | Purpose |
|------|---------|
| `-DANDROID_NDK` | Android NDK build indicator |
| `-DLOG_NDEBUG` | Disable debug logging in release |

### UVCCamera + libusb Specific

| Flag | Purpose |
|------|---------|
| `-DACCESS_RAW_DESCRIPTORS` | Enable raw USB descriptor access |
| `-O3` | Maximum optimization |
| `-fstrict-aliasing` | Strict aliasing rules |
| `-fprefetch-loop-arrays` | Loop prefetch optimization |

### libuvc Specific

| Flag | Purpose |
|------|---------|
| `-DUVC_DEBUGGING` | UVC debug output |

### libjpeg-turbo Specific

| Flag | Purpose |
|------|---------|
| `-DELF` | ELF binary format (assembly) |
| `-DSIZEOF_SIZE_T=N` | Architecture pointer size |
| `-D__x86_64__` | x86_64 assembly indicator |

---

## System Library Dependencies

| Library | Purpose | Used By |
|---------|---------|---------|
| `liblog.so` | Android logging | All |
| `libandroid.so` | Android native APIs | UVCCamera |
| `libnativewindow.so` | ANativeWindow API | UVCCamera |
| `libEGL.so` | EGL context | UVCCamera |
| `libGLESv2.so` | OpenGL ES 2.0 | UVCCamera |
| `libdl.so` | Dynamic loading | libjpeg-turbo |

---

## License Summary

| Component | License | Compatibility |
|-----------|---------|---------------|
| UVCCamera | Apache 2.0 | ✅ Permissive |
| libuvc | BSD | ✅ Permissive |
| libusb | LGPL v2.1 | ⚠️ Shared library required |
| libjpeg-turbo | IJG + BSD | ✅ Permissive |
| rapidjson | MIT | ✅ Permissive |

**Note:** libusb's LGPL license requires dynamic linking (satisfied by building as .so).

---

## Platform Target Evolution

### Current vs Target Configuration

| Setting | Current | Target | Reference |
|---------|---------|--------|-----------|
| `APP_PLATFORM` | android-26 | android-36 | Android 16 |
| NDK Version | r21 | r28+ | C++20/C++23 support |
| C++ Standard | C++14 | C++23 | std::jthread, coroutines |
| Kernel Target | 4.x | ACK 6.1+ | V4L2 data_offset support |

### Android 16 Considerations

1. **USB Protection (Advanced Data Protection)**
   - New connections blocked while screen locked
   - Existing FDs persist through lock/unlock
   - hardReset() requires unlock awareness
   - See **AUDIT-001-appendix-background.md** Appendix D.2

2. **Foreground Service Requirement (Android 14+)**
   - `connectedDevice` service type required
   - Without this, app killed during Doze
   - Kotlin layer responsibility (not in JNI scope)

3. **16KB Page Alignment**
   - Already implemented: `-Wl,-z,max-page-size=16384`
   - Required for Android 15+ kernel compatibility

### Kernel/Driver Dependencies

| Component | Kernel Feature | Status | Notes |
|-----------|----------------|--------|-------|
| UVC streaming | V4L2 driver | External | See Appendix C.2 (quirk flags) |
| Buffer handling | V4L2 data_offset | Future | ACK 6.1+ required |
| USB transport | usbfs | ✅ Working | android_usbfs.c modifications |
| Hardware buffers | AHardwareBuffer | ✅ Working | API 26+ |

---

## Modernization Notes

### Current Build System
- **ndk-build** with Android.mk files
- Manual include path management
- Architecture-specific conditional compilation

### Recommended Migration Path
1. Convert Android.mk → CMakeLists.txt
2. Use `find_package()` for dependencies
3. Leverage CMake generator expressions for ABI handling
4. Enable CMake Presets for build configurations
5. **Target NDK r28+** for full C++20 support (see AUDIT-001-appendix-background.md)

### Key Files for Migration

| File | Priority | Complexity |
|------|----------|------------|
| `Application.mk` | High | Low - Simple NDK config |
| `UVCCamera/Android.mk` | High | Medium - Main library |
| `libjpeg-turbo/Android.mk` | Medium | High - SIMD complexity |
| `libusb/libusb.mk` | Medium | Low |
| `libuvc/Android.mk` | Medium | Low |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| INVENTORY-005 | Dependency graph for this build config |
| INVENTORY-006 | Baseline metrics including platform targets |
| **AUDIT-001-appendix-background.md** | V4L2/UVC kernel context, Android 16 platform |
| CONCURRENCY-009 | C++20 migration path (std::jthread) |

---

*End of INVENTORY-004*
