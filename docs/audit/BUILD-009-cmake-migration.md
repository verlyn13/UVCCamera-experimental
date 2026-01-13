# BUILD-009: CMake Migration Planning

**Audit:** AUDIT-005 Build System Archaeology
**Generated:** 2026-01-11
**Target:** ndk-build to CMake Migration Strategy

---

## Summary

| Aspect | Current | Target |
|--------|---------|--------|
| Build system | ndk-build | CMake |
| Build files | 5 Android.mk + 2 Application.mk | ~5 CMakeLists.txt |
| Configuration | Makefile variables | Modern CMake targets |
| IDE support | Limited | Full (CLion, AS) |

---

## 1. Important Clarification

### ndk-build is NOT Deprecated

**From Official NDK Documentation:**
> "ndk-build is not deprecated. If you have an existing ndk-build project that works well for you, there is no need to migrate to CMake."

**Migration Rationale:**
- Better IDE integration (Android Studio, CLion)
- Modern target-based dependency management
- Cross-platform compatibility
- Generator expressions for complex builds
- **NOT** because ndk-build is going away

---

## 2. Migration Mapping Table

### Variable Mapping

| ndk-build | CMake | Notes |
|-----------|-------|-------|
| `LOCAL_MODULE` | `add_library(name ...)` | Target name |
| `LOCAL_SRC_FILES` | `target_sources()` | Source files |
| `LOCAL_C_INCLUDES` | `target_include_directories(PRIVATE)` | Private includes |
| `LOCAL_EXPORT_C_INCLUDES` | `target_include_directories(PUBLIC)` | Exported includes |
| `LOCAL_CFLAGS` | `target_compile_options()` | Compile flags |
| `LOCAL_CPPFLAGS` | `target_compile_options()` | C++ flags |
| `LOCAL_LDFLAGS` | `target_link_options()` | Link flags |
| `LOCAL_LDLIBS` | `target_link_libraries()` | System libraries |
| `LOCAL_SHARED_LIBRARIES` | `target_link_libraries()` | Shared deps |
| `LOCAL_STATIC_LIBRARIES` | `target_link_libraries()` | Static deps |
| `LOCAL_WHOLE_STATIC_LIBRARIES` | `$<LINK_LIBRARY:WHOLE_ARCHIVE,...>` | Whole archive |
| `LOCAL_ARM_MODE` | `set(CMAKE_ANDROID_ARM_MODE)` | ARM mode |
| `LOCAL_ARM_NEON` | `set(CMAKE_ANDROID_ARM_NEON)` | NEON flag |

### Application.mk Mapping

| ndk-build | CMake | Notes |
|-----------|-------|-------|
| `APP_PLATFORM` | `ANDROID_PLATFORM` | Toolchain variable |
| `APP_ABI` | `ANDROID_ABI` | Toolchain variable |
| `APP_STL` | `ANDROID_STL` | Toolchain variable |
| `APP_OPTIM` | `CMAKE_BUILD_TYPE` | Release/Debug |
| `APP_CFLAGS` | `add_compile_options()` | Global flags |
| `APP_LDFLAGS` | `add_link_options()` | Global link flags |

---

## 3. Migration Strategy

### Phase 1: Parallel Build Setup

Create CMake alongside existing ndk-build for validation:

```
jni/
├── Android.mk              # Keep existing
├── Application.mk          # Keep existing
├── CMakeLists.txt          # NEW: Root CMake
├── UVCCamera/
│   ├── Android.mk          # Keep existing
│   └── CMakeLists.txt      # NEW: UVCCamera module
├── libjpeg-turbo-1.5.0/
│   ├── Android.mk          # Keep existing
│   └── CMakeLists.txt      # NEW: JPEG module
├── libusb/
│   └── android/jni/
│       ├── Android.mk      # Keep existing
│       └── CMakeLists.txt  # NEW: USB module
└── libuvc/
    └── android/jni/
        ├── Android.mk      # Keep existing
        └── CMakeLists.txt  # NEW: UVC module
```

### Phase 2: Binary Comparison

Build both systems and compare:

```bash
# ndk-build
cd jni && ndk-build

# CMake
cmake -B build-cmake \
    -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-26
cmake --build build-cmake

# Compare sizes
ls -la obj/local/arm64-v8a/*.so
ls -la build-cmake/*.so
```

### Phase 3: Gradle Integration

Update build.gradle:

```groovy
android {
    externalNativeBuild {
        // cmake {
        //     path file('src/main/jni/CMakeLists.txt')
        // }

        // OR keep ndk-build:
        ndkBuild {
            path file('src/main/jni/Android.mk')
        }
    }
}
```

### Phase 4: Remove ndk-build (Optional)

After validation, optionally remove Android.mk files.

---

## 4. Module-by-Module Migration

### 4.1 Root CMakeLists.txt

```cmake
cmake_minimum_required(VERSION 3.22.1)
project(UVCCamera VERSION 1.0.0 LANGUAGES C CXX ASM)

# NDK validation
if(NOT ANDROID)
    message(FATAL_ERROR "This project requires Android NDK toolchain")
endif()

# Global settings
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 16KB page alignment (Android 15+)
add_link_options(-Wl,-z,max-page-size=16384)

# Add subdirectories
add_subdirectory(libjpeg-turbo-1.5.0)
add_subdirectory(libusb/android/jni)
add_subdirectory(libuvc/android/jni)
add_subdirectory(UVCCamera)
```

### 4.2 libjpeg-turbo CMakeLists.txt

```cmake
# libjpeg-turbo-1.5.0/CMakeLists.txt

# Source files (common)
set(JPEG_SOURCES
    jcapimin.c jcapistd.c jccoefct.c jccolor.c jcdctmgr.c
    jchuff.c jcinit.c jcmainct.c jcmarker.c jcmaster.c
    jcomapi.c jcparam.c jcphuff.c jcprepct.c jcsample.c
    jctrans.c jdapimin.c jdapistd.c jdatadst.c jdatasrc.c
    jdcoefct.c jdcolor.c jddctmgr.c jdhuff.c jdinput.c
    jdmainct.c jdmarker.c jdmaster.c jdmerge.c jdphuff.c
    jdpostct.c jdsample.c jdtrans.c jerror.c jfdctflt.c
    jfdctfst.c jfdctint.c jidctflt.c jidctfst.c jidctint.c
    jidctred.c jquant1.c jquant2.c jutils.c jmemmgr.c
    jmemnobs.c jaricom.c jcarith.c jdarith.c
    turbojpeg.c transupp.c jdatadst-tj.c jdatasrc-tj.c
)

# ABI-specific SIMD
if(ANDROID_ABI STREQUAL "arm64-v8a")
    list(APPEND JPEG_SOURCES simd/jsimd_arm64.c simd/jsimd_arm64_neon.S)
    set(SIZEOF_SIZE_T 8)
elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    list(APPEND JPEG_SOURCES simd/jsimd_arm.c simd/jsimd_arm_neon.S)
    set(SIZEOF_SIZE_T 4)
else()
    list(APPEND JPEG_SOURCES jsimd_none.c)
    set(SIZEOF_SIZE_T 4)
endif()

# Static library
add_library(jpeg-turbo1500_static STATIC ${JPEG_SOURCES})
target_include_directories(jpeg-turbo1500_static
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_compile_definitions(jpeg-turbo1500_static PRIVATE
    ANDROID_NDK
    SIZEOF_SIZE_T=${SIZEOF_SIZE_T}
)

# Shared library (wraps static)
add_library(jpeg-turbo1500 SHARED)
target_link_libraries(jpeg-turbo1500 PRIVATE
    $<LINK_LIBRARY:WHOLE_ARCHIVE,jpeg-turbo1500_static>
    dl
)
```

### 4.3 libusb CMakeLists.txt

```cmake
# libusb/android/jni/CMakeLists.txt

set(LIBUSB_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

set(LIBUSB_SOURCES
    ${LIBUSB_ROOT}/libusb/core.c
    ${LIBUSB_ROOT}/libusb/descriptor.c
    ${LIBUSB_ROOT}/libusb/hotplug.c
    ${LIBUSB_ROOT}/libusb/io.c
    ${LIBUSB_ROOT}/libusb/sync.c
    ${LIBUSB_ROOT}/libusb/strerror.c
    ${LIBUSB_ROOT}/libusb/os/android_usbfs.c
    ${LIBUSB_ROOT}/libusb/os/poll_posix.c
    ${LIBUSB_ROOT}/libusb/os/threads_posix.c
    ${LIBUSB_ROOT}/libusb/os/android_netlink.c
)

# Static library
add_library(libusb100_static STATIC ${LIBUSB_SOURCES})
target_include_directories(libusb100_static
    PRIVATE ${LIBUSB_ROOT}
    PUBLIC ${LIBUSB_ROOT}/libusb
)
target_compile_definitions(libusb100_static PRIVATE
    ANDROID_NDK
    LOG_NDEBUG
    ACCESS_RAW_DESCRIPTORS
)
target_compile_options(libusb100_static PRIVATE
    -O3 -fstrict-aliasing -fprefetch-loop-arrays
)

# Shared library
add_library(libusb100 SHARED)
target_link_libraries(libusb100 PRIVATE
    $<LINK_LIBRARY:WHOLE_ARCHIVE,libusb100_static>
    log
)
```

### 4.4 libuvc CMakeLists.txt

```cmake
# libuvc/android/jni/CMakeLists.txt

set(LIBUVC_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

set(LIBUVC_SOURCES
    ${LIBUVC_ROOT}/src/ctrl.c
    ${LIBUVC_ROOT}/src/device.c
    ${LIBUVC_ROOT}/src/diag.c
    ${LIBUVC_ROOT}/src/frame.c
    ${LIBUVC_ROOT}/src/frame-mjpeg.c
    ${LIBUVC_ROOT}/src/init.c
    ${LIBUVC_ROOT}/src/stream.c
)

# Static library
add_library(libuvc_static STATIC ${LIBUVC_SOURCES})
target_include_directories(libuvc_static
    PRIVATE ${LIBUVC_ROOT}
    PUBLIC
        ${LIBUVC_ROOT}/include
        ${LIBUVC_ROOT}/include/libuvc
)
target_compile_definitions(libuvc_static PRIVATE
    ANDROID_NDK
    LOG_NDEBUG
    UVC_DEBUGGING
)
target_link_libraries(libuvc_static PUBLIC
    jpeg-turbo1500
    libusb100
)

# Shared library
add_library(uvc SHARED)
target_link_libraries(uvc PRIVATE
    $<LINK_LIBRARY:WHOLE_ARCHIVE,libuvc_static>
    log
)
```

### 4.5 UVCCamera CMakeLists.txt

```cmake
# UVCCamera/CMakeLists.txt

set(UVCCAMERA_SOURCES
    _onload.cpp
    utilbase.cpp
    HandleManager.cpp
    UVCCamera.cpp
    UVCPreview.cpp
    UVCButtonCallback.cpp
    UVCStatusCallback.cpp
    UVCReadinessCallback.cpp
    Parameters.cpp
    FrameBufferRing.cpp
    FrameBufferJNI.cpp
    LayoutContract.cpp
    EGLImageHelperJNI.cpp
    serenegiant_usb_UVCCamera.cpp
)

add_library(UVCCamera SHARED ${UVCCAMERA_SOURCES})

target_include_directories(UVCCamera PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../rapidjson/include
)

target_compile_definitions(UVCCamera PRIVATE
    ANDROID_NDK
    LOG_NDEBUG
    ACCESS_RAW_DESCRIPTORS
)

target_compile_options(UVCCamera PRIVATE
    -O3 -fstrict-aliasing -fprefetch-loop-arrays
)

target_link_libraries(UVCCamera PRIVATE
    libusb100
    uvc
    jpeg-turbo1500_static
    android
    log
    nativewindow
    EGL
    GLESv2
    dl
)
```

---

## 5. Gradle CMake Integration

```groovy
// lib/build.gradle

android {
    compileSdk 34

    defaultConfig {
        minSdk 26
        targetSdk 34

        externalNativeBuild {
            cmake {
                cppFlags "-std=c++17"
                arguments "-DANDROID_STL=c++_shared"
            }
        }

        ndk {
            abiFilters 'armeabi-v7a', 'arm64-v8a'
        }
    }

    externalNativeBuild {
        cmake {
            path file('src/main/jni/CMakeLists.txt')
            version "3.22.1"
        }
    }
}
```

---

## 6. Migration Risks

### Low Risk

| Risk | Mitigation |
|------|------------|
| Symbol visibility changes | Test JNI loading thoroughly |
| Optimization differences | Compare binary sizes |
| Link order changes | Explicit dependency ordering |

### Medium Risk

| Risk | Mitigation |
|------|------------|
| Assembly compilation | Verify SIMD output |
| WHOLE_ARCHIVE syntax | CMake 3.24+ required for generator |
| Build tool differences | Parallel builds for validation |

### High Risk

| Risk | Mitigation |
|------|------------|
| None identified | - |

---

## 7. Validation Checklist

### Pre-Migration

- [ ] All ndk-build artifacts documented (BUILD-008)
- [ ] Baseline functionality verified
- [ ] Test coverage adequate

### Post-Migration

- [ ] All .so files produced
- [ ] File sizes within 10% of ndk-build
- [ ] JNI methods loadable
- [ ] Preview functionality works
- [ ] Capture functionality works
- [ ] Memory profiling shows no leaks

---

## 8. Decision Matrix

### Should You Migrate?

| Factor | Stay ndk-build | Migrate CMake |
|--------|----------------|---------------|
| Works currently | ✓ | - |
| IDE integration needed | - | ✓ |
| Cross-platform targets | - | ✓ |
| New team members | - | ✓ |
| Build script modifications | ✓ | - |

**Recommendation:** Migration is optional. Consider only if IDE integration or cross-platform builds are required.

---

## 9. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| MIG-001 | Info | Migration is optional | Only if benefits outweigh effort |
| MIG-002 | Low | WHOLE_ARCHIVE requires CMake 3.24+ | Use modern CMake |
| MIG-003 | Info | Parallel build validation needed | Build both systems |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **BUILD-001** | Source module list |
| **BUILD-003** | Compiler flags to port |
| **BUILD-004** | Dependency order |
| **BUILD-010** | Complete CMake template |

---

*End of BUILD-009*
