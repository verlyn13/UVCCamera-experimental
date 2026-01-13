# BUILD-008: Build Artifact Mapping

**Audit:** AUDIT-005 Build System Archaeology
**Generated:** 2026-01-11
**Target:** Build Output Analysis

---

## Summary

| Metric | Count |
|--------|-------|
| Shared libraries | 4 per ABI |
| Static libraries | 4 per ABI |
| Total binaries | 16 (2 ABIs × 8 libraries) |
| Runtime dependencies | 1 (libc++_shared.so) |

---

## 1. Build Artifact Inventory

### Shared Libraries (.so)

| Artifact | Module | Load Order |
|----------|--------|------------|
| libjpeg-turbo1500.so | jpeg-turbo1500 | 1 (no deps) |
| libusb100.so | libusb100 | 1 (no deps) |
| libuvc.so | uvc | 2 (deps: jpeg, usb) |
| libUVCCamera.so | UVCCamera | 3 (deps: uvc, usb) |
| libc++_shared.so | STL runtime | 0 (system load) |

### Static Libraries (.a)

| Artifact | Module | Purpose |
|----------|--------|---------|
| libjpeg-turbo1500_static.a | jpeg-turbo1500_static | WHOLE_STATIC into .so |
| libusb100_static.a | libusb100_static | WHOLE_STATIC into .so |
| libuvc_static.a | libuvc_static | WHOLE_STATIC into .so |

---

## 2. Directory Structure

### ndk-build Output

```
obj/
├── local/
│   ├── armeabi-v7a/
│   │   ├── objs/
│   │   │   ├── UVCCamera/
│   │   │   │   ├── _onload.o
│   │   │   │   ├── HandleManager.o
│   │   │   │   ├── UVCCamera.o
│   │   │   │   └── ... (14 files)
│   │   │   ├── jpeg-turbo1500_static/
│   │   │   │   └── ... (45+ files)
│   │   │   ├── libusb100_static/
│   │   │   │   └── ... (10 files)
│   │   │   └── libuvc_static/
│   │   │       └── ... (7 files)
│   │   ├── libjpeg-turbo1500_static.a
│   │   ├── libusb100_static.a
│   │   ├── libuvc_static.a
│   │   ├── libjpeg-turbo1500.so
│   │   ├── libusb100.so
│   │   ├── libuvc.so
│   │   └── libUVCCamera.so
│   └── arm64-v8a/
│       └── ... (same structure)
└── libs/
    ├── armeabi-v7a/
    │   ├── libjpeg-turbo1500.so
    │   ├── libusb100.so
    │   ├── libuvc.so
    │   ├── libUVCCamera.so
    │   └── libc++_shared.so
    └── arm64-v8a/
        └── ... (same files)
```

### APK Output Location

```
lib/build/outputs/aar/lib-release.aar
└── jni/
    ├── armeabi-v7a/
    │   └── libUVCCamera.so (+ deps)
    └── arm64-v8a/
        └── libUVCCamera.so (+ deps)
```

---

## 3. Source-to-Object Mapping

### UVCCamera Module

| Source File | Object File | Size (est.) |
|-------------|-------------|-------------|
| _onload.cpp | _onload.o | 8 KB |
| utilbase.cpp | utilbase.o | 12 KB |
| HandleManager.cpp | HandleManager.o | 16 KB |
| UVCCamera.cpp | UVCCamera.o | 80 KB |
| UVCPreview.cpp | UVCPreview.o | 120 KB |
| UVCButtonCallback.cpp | UVCButtonCallback.o | 8 KB |
| UVCStatusCallback.cpp | UVCStatusCallback.o | 8 KB |
| UVCReadinessCallback.cpp | UVCReadinessCallback.o | 8 KB |
| Parameters.cpp | Parameters.o | 24 KB |
| FrameBufferRing.cpp | FrameBufferRing.o | 20 KB |
| FrameBufferJNI.cpp | FrameBufferJNI.o | 16 KB |
| LayoutContract.cpp | LayoutContract.o | 12 KB |
| EGLImageHelperJNI.cpp | EGLImageHelperJNI.o | 20 KB |
| serenegiant_usb_UVCCamera.cpp | serenegiant_usb_UVCCamera.o | 40 KB |

### libjpeg-turbo Module (Core Files)

| Source File | Object File | Notes |
|-------------|-------------|-------|
| jcapimin.c | jcapimin.o | Compress API |
| jdapimin.c | jdapimin.o | Decompress API |
| turbojpeg.c | turbojpeg.o | TurboJPEG API |
| simd/jsimd_arm64.c | jsimd_arm64.o | SIMD dispatcher |
| simd/jsimd_arm64_neon.S | jsimd_arm64_neon.o | NEON assembly |

### libusb Module

| Source File | Object File | Notes |
|-------------|-------------|-------|
| core.c | core.o | Core API |
| descriptor.c | descriptor.o | USB descriptors |
| io.c | io.o | I/O operations |
| android_usbfs.c | android_usbfs.o | Android-specific |
| android_netlink.c | android_netlink.o | Android-specific |

### libuvc Module

| Source File | Object File | Notes |
|-------------|-------------|-------|
| ctrl.c | ctrl.o | UVC controls |
| device.c | device.o | Device handling |
| frame.c | frame.o | Frame processing |
| frame-mjpeg.c | frame-mjpeg.o | MJPEG frames |
| stream.c | stream.o | Streaming |

---

## 4. Symbol Export Analysis

### Exported JNI Symbols (libUVCCamera.so)

```
JNI_OnLoad
Java_com_serenegiant_usb_UVCCamera_nativeCreate
Java_com_serenegiant_usb_UVCCamera_nativeDestroy
Java_com_serenegiant_usb_UVCCamera_nativeConnect
Java_com_serenegiant_usb_UVCCamera_nativeRelease
Java_com_serenegiant_usb_UVCCamera_nativeSetPreviewSize
Java_com_serenegiant_usb_UVCCamera_nativeSetPreviewDisplay
Java_com_serenegiant_usb_UVCCamera_nativeStartPreview
Java_com_serenegiant_usb_UVCCamera_nativeStopPreview
Java_com_serenegiant_usb_UVCCamera_nativeSetFrameCallback
Java_com_serenegiant_usb_UVCCamera_nativeCaptureStill
... (additional JNI methods)
```

### Library Dependencies (via DT_NEEDED)

```
libUVCCamera.so:
  DT_NEEDED: libuvc.so
  DT_NEEDED: libusb100.so
  DT_NEEDED: libjpeg-turbo1500.so (via static)
  DT_NEEDED: libc++_shared.so
  DT_NEEDED: liblog.so
  DT_NEEDED: libandroid.so
  DT_NEEDED: libnativewindow.so
  DT_NEEDED: libEGL.so
  DT_NEEDED: libGLESv2.so
  DT_NEEDED: libdl.so
```

---

## 5. Build Configuration Matrix

### Per-Module Build Outputs

| Module | Static Output | Shared Output | Depends On |
|--------|---------------|---------------|------------|
| jpeg-turbo1500_static | ✓ .a | - | - |
| jpeg-turbo1500 | - | ✓ .so | jpeg_static |
| libusb100_static | ✓ .a | - | - |
| libusb100 | - | ✓ .so | usb_static |
| libuvc_static | ✓ .a | - | jpeg, usb |
| uvc | - | ✓ .so | uvc_static |
| UVCCamera | - | ✓ .so | uvc, usb, jpeg_static |

---

## 6. Size Analysis

### Estimated Library Sizes

| Library | armeabi-v7a | arm64-v8a | Notes |
|---------|-------------|-----------|-------|
| libUVCCamera.so | ~800 KB | ~1.1 MB | Main JNI |
| libjpeg-turbo1500.so | ~350 KB | ~400 KB | SIMD code |
| libusb100.so | ~180 KB | ~220 KB | USB stack |
| libuvc.so | ~120 KB | ~150 KB | UVC protocol |
| libc++_shared.so | ~290 KB | ~340 KB | STL runtime |
| **Total per ABI** | ~1.74 MB | ~2.21 MB | |
| **Total (both ABIs)** | | ~3.95 MB | |

### Static Library Sizes

| Library | armeabi-v7a | arm64-v8a |
|---------|-------------|-----------|
| libjpeg-turbo1500_static.a | ~2.5 MB | ~3.0 MB |
| libusb100_static.a | ~400 KB | ~500 KB |
| libuvc_static.a | ~250 KB | ~300 KB |

**Note:** Static libraries are larger due to unrestricted symbol inclusion; shared libraries are stripped.

---

## 7. APK Integration

### Gradle Integration Points

```groovy
// In lib/build.gradle
android {
    externalNativeBuild {
        ndkBuild {
            path file('src/main/jni/Android.mk')
        }
    }

    defaultConfig {
        ndk {
            abiFilters 'armeabi-v7a', 'arm64-v8a'
        }
    }
}
```

### AAR Structure

```
lib-release.aar
├── AndroidManifest.xml
├── classes.jar
├── R.txt
├── res/
├── jni/
│   ├── armeabi-v7a/
│   │   ├── libUVCCamera.so
│   │   ├── libjpeg-turbo1500.so
│   │   ├── libusb100.so
│   │   ├── libuvc.so
│   │   └── libc++_shared.so
│   └── arm64-v8a/
│       └── (same files)
└── proguard.txt
```

---

## 8. Build Verification Script

```bash
#!/bin/bash
# verify-artifacts.sh - Verify build outputs

BUILD_DIR="obj/local"
EXPECTED_SHARED=(
    "libjpeg-turbo1500.so"
    "libusb100.so"
    "libuvc.so"
    "libUVCCamera.so"
)
EXPECTED_STATIC=(
    "libjpeg-turbo1500_static.a"
    "libusb100_static.a"
    "libuvc_static.a"
)

for ABI in armeabi-v7a arm64-v8a; do
    echo "=== Checking $ABI ==="

    for lib in "${EXPECTED_SHARED[@]}"; do
        if [ -f "$BUILD_DIR/$ABI/$lib" ]; then
            SIZE=$(ls -lh "$BUILD_DIR/$ABI/$lib" | awk '{print $5}')
            echo "[OK] $lib ($SIZE)"
        else
            echo "[MISSING] $lib"
        fi
    done

    for lib in "${EXPECTED_STATIC[@]}"; do
        if [ -f "$BUILD_DIR/$ABI/$lib" ]; then
            SIZE=$(ls -lh "$BUILD_DIR/$ABI/$lib" | awk '{print $5}')
            echo "[OK] $lib ($SIZE)"
        else
            echo "[MISSING] $lib"
        fi
    done
done
```

---

## 9. CMake Output Mapping

### Equivalent CMake Outputs

```cmake
# Static libraries
add_library(jpeg-turbo1500_static STATIC ...)
# Output: libjpeg-turbo1500_static.a

# Shared libraries
add_library(jpeg-turbo1500 SHARED ...)
# Output: libjpeg-turbo1500.so

# Main library
add_library(UVCCamera SHARED ...)
# Output: libUVCCamera.so
```

### CMake Output Directories

```
cmake-build/
├── armeabi-v7a/
│   ├── libjpeg-turbo1500.a
│   ├── libjpeg-turbo1500.so
│   └── ...
└── arm64-v8a/
    └── ...
```

---

## 10. Artifact Naming Conventions

### ndk-build Naming Rules

| LOCAL_MODULE | Output Name | Notes |
|--------------|-------------|-------|
| UVCCamera | libUVCCamera.so | `lib` prefix added |
| jpeg-turbo1500 | libjpeg-turbo1500.so | Hyphen preserved |
| libusb100 | libusb100.so | Already has `lib` |
| uvc | libuvc.so | `lib` prefix added |

### Name Stripping Behavior

```makefile
# ndk-build strips 'lib' prefix for LOCAL_SHARED_LIBRARIES
LOCAL_SHARED_LIBRARIES += usb100  # Refers to libusb100.so
LOCAL_SHARED_LIBRARIES += uvc     # Refers to libuvc.so
```

---

## 11. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| ART-001 | Info | Static libs are large | Normal for archives |
| ART-002 | Info | 4 shared libs per ABI | Consider consolidation |
| ART-003 | Low | No debug symbols in release | Expected for release |

### Positive Findings

| ID | Finding |
|----|---------|
| ART-P01 | Clean separation of static/shared |
| ART-P02 | Proper WHOLE_STATIC linkage |
| ART-P03 | Consistent naming conventions |
| ART-P04 | All expected artifacts present |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **BUILD-001** | Module definitions |
| **BUILD-004** | Dependency graph |
| **BUILD-007** | ABI configuration |
| **BUILD-010** | CMake outputs |

---

*End of BUILD-008*
