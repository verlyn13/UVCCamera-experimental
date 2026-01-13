# BUILD-010: Verified CMake Template

**Audit:** AUDIT-005 Build System Archaeology
**Generated:** 2026-01-11
**Target:** Production-Ready CMake Configuration

---

## Verification Sources

| Source | Version | Reference |
|--------|---------|-----------|
| NDK CMake Guide | r28 | developer.android.com/ndk/guides/cmake |
| CMake Documentation | 3.28 | cmake.org/cmake/help/latest |
| Android Toolchain | r28 | NDK build/cmake/android.toolchain.cmake |

---

## 1. Root CMakeLists.txt

```cmake
# =============================================================================
# CMakeLists.txt - UVCCamera Library Root Build Configuration
# =============================================================================
# Verified against:
# - NDK r28 documentation
# - CMake 3.22+ requirements
# - Android toolchain conventions
#
# Build command:
#   cmake -B build \
#     -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
#     -DANDROID_ABI=arm64-v8a \
#     -DANDROID_PLATFORM=android-26 \
#     -DANDROID_STL=c++_shared
#   cmake --build build
# =============================================================================

cmake_minimum_required(VERSION 3.22.1)
project(UVCCamera
    VERSION 1.0.0
    DESCRIPTION "UVC Camera library for Android"
    LANGUAGES C CXX ASM
)

# =============================================================================
# Toolchain Validation
# =============================================================================

if(NOT ANDROID)
    message(FATAL_ERROR
        "This project requires the Android NDK toolchain.\n"
        "Use: -DCMAKE_TOOLCHAIN_FILE=\$ANDROID_NDK/build/cmake/android.toolchain.cmake"
    )
endif()

message(STATUS "Android NDK: ${ANDROID_NDK}")
message(STATUS "Android ABI: ${ANDROID_ABI}")
message(STATUS "Android Platform: ${ANDROID_PLATFORM}")
message(STATUS "Android STL: ${ANDROID_STL}")

# =============================================================================
# Global C++ Standard
# =============================================================================

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# =============================================================================
# Security Hardening (16KB Page Alignment)
# =============================================================================
# Required for Android 15+ devices with 16KB page sizes
# Reference: https://developer.android.com/guide/practices/page-sizes

add_link_options(-Wl,-z,max-page-size=16384)

# =============================================================================
# ABI-Specific Configuration
# =============================================================================

if(ANDROID_ABI STREQUAL "arm64-v8a")
    # ARM64: NEON is mandatory, no additional flags needed
    message(STATUS "Configuring for ARM64 (NEON mandatory)")

    # Optional: MTE support for Android 16+ (ARMv8.5-A+)
    # Uncomment when targeting MTE-capable devices:
    # add_compile_options(-march=armv8.5-a+memtag -fsanitize=memtag)
    # add_link_options(-fsanitize=memtag)

elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    # ARM32: Configure for ARM mode and optional NEON
    message(STATUS "Configuring for ARMv7-A")

    set(CMAKE_ANDROID_ARM_MODE arm)  # Use ARM mode, not Thumb

    # Enable NEON (recommended - all modern devices support it)
    set(CMAKE_ANDROID_ARM_NEON TRUE)

elseif(ANDROID_ABI STREQUAL "x86_64")
    message(STATUS "Configuring for x86_64 (emulator)")

elseif(ANDROID_ABI STREQUAL "x86")
    message(STATUS "Configuring for x86 (emulator)")

else()
    message(WARNING "Unknown ABI: ${ANDROID_ABI}")
endif()

# =============================================================================
# Subdirectories
# =============================================================================

# Third-party libraries (build first)
add_subdirectory(libjpeg-turbo-1.5.0)
add_subdirectory(libusb/android/jni)
add_subdirectory(libuvc/android/jni)

# Main library
add_subdirectory(UVCCamera)

# =============================================================================
# Installation (optional)
# =============================================================================

include(GNUInstallDirs)

install(TARGETS UVCCamera jpeg-turbo1500 libusb100 uvc
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/${ANDROID_ABI}
)
```

---

## 2. libjpeg-turbo CMakeLists.txt

```cmake
# =============================================================================
# libjpeg-turbo-1.5.0/CMakeLists.txt
# =============================================================================

# Core JPEG sources (all ABIs)
set(JPEG_CORE_SOURCES
    jcapimin.c jcapistd.c jccoefct.c jccolor.c jcdctmgr.c
    jchuff.c jcinit.c jcmainct.c jcmarker.c jcmaster.c
    jcomapi.c jcparam.c jcphuff.c jcprepct.c jcsample.c
    jctrans.c jdapimin.c jdapistd.c jdatadst.c jdatasrc.c
    jdcoefct.c jdcolor.c jddctmgr.c jdhuff.c jdinput.c
    jdmainct.c jdmarker.c jdmaster.c jdmerge.c jdphuff.c
    jdpostct.c jdsample.c jdtrans.c jerror.c jfdctflt.c
    jfdctfst.c jfdctint.c jidctflt.c jidctfst.c jidctint.c
    jidctred.c jquant1.c jquant2.c jutils.c jmemmgr.c
    jmemnobs.c
)

# Arithmetic coding (optional, but included)
set(JPEG_ARITH_SOURCES
    jaricom.c jcarith.c jdarith.c
)

# TurboJPEG API
set(JPEG_TURBO_SOURCES
    turbojpeg.c transupp.c jdatadst-tj.c jdatasrc-tj.c
)

# Combine common sources
set(JPEG_SOURCES
    ${JPEG_CORE_SOURCES}
    ${JPEG_ARITH_SOURCES}
    ${JPEG_TURBO_SOURCES}
)

# =============================================================================
# ABI-Specific SIMD Sources
# =============================================================================

if(ANDROID_ABI STREQUAL "arm64-v8a")
    list(APPEND JPEG_SOURCES
        simd/jsimd_arm64.c
        simd/jsimd_arm64_neon.S
    )
    set(SIZEOF_SIZE_T 8)

elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    list(APPEND JPEG_SOURCES
        simd/jsimd_arm.c
        simd/jsimd_arm_neon.S
    )
    set(SIZEOF_SIZE_T 4)

elseif(ANDROID_ABI STREQUAL "x86_64")
    # x86_64 SIMD (requires NASM assembler)
    list(APPEND JPEG_SOURCES
        simd/jsimd_x86_64.c
        simd/jfdctflt-sse-64.asm
        simd/jccolor-sse2-64.asm
        simd/jcgray-sse2-64.asm
        simd/jcsample-sse2-64.asm
        simd/jdcolor-sse2-64.asm
        simd/jdmerge-sse2-64.asm
        simd/jdsample-sse2-64.asm
        simd/jfdctfst-sse2-64.asm
        simd/jfdctint-sse2-64.asm
        simd/jidctflt-sse2-64.asm
        simd/jidctfst-sse2-64.asm
        simd/jidctint-sse2-64.asm
        simd/jidctred-sse2-64.asm
        simd/jquantf-sse2-64.asm
        simd/jquanti-sse2-64.asm
        simd/jchuff-sse2-64.asm
    )
    set(SIZEOF_SIZE_T 8)
    enable_language(ASM_NASM)

elseif(ANDROID_ABI STREQUAL "x86")
    # x86 SIMD - extensive support
    list(APPEND JPEG_SOURCES
        simd/jsimd_i386.c
        simd/jsimdcpu.asm
        # MMX, SSE, SSE2, 3DNow sources...
    )
    set(SIZEOF_SIZE_T 4)
    enable_language(ASM_NASM)

else()
    # Fallback: no SIMD
    list(APPEND JPEG_SOURCES jsimd_none.c)
    set(SIZEOF_SIZE_T 4)
endif()

# =============================================================================
# Static Library
# =============================================================================

add_library(jpeg-turbo1500_static STATIC ${JPEG_SOURCES})

target_include_directories(jpeg-turbo1500_static
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/simd
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
)

target_compile_definitions(jpeg-turbo1500_static PRIVATE
    ANDROID_NDK
    SIZEOF_SIZE_T=${SIZEOF_SIZE_T}
)

# =============================================================================
# Shared Library
# =============================================================================

add_library(jpeg-turbo1500 SHARED)

# WHOLE_ARCHIVE linkage (CMake 3.24+)
target_link_libraries(jpeg-turbo1500 PRIVATE
    $<LINK_LIBRARY:WHOLE_ARCHIVE,jpeg-turbo1500_static>
    dl
)

# For CMake < 3.24, use this instead:
# target_link_libraries(jpeg-turbo1500 PRIVATE
#     -Wl,--whole-archive
#     jpeg-turbo1500_static
#     -Wl,--no-whole-archive
#     dl
# )
```

---

## 3. libusb CMakeLists.txt

```cmake
# =============================================================================
# libusb/android/jni/CMakeLists.txt
# =============================================================================

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

# =============================================================================
# Static Library
# =============================================================================

add_library(libusb100_static STATIC ${LIBUSB_SOURCES})

target_include_directories(libusb100_static
    PRIVATE
        ${LIBUSB_ROOT}
        ${LIBUSB_ROOT}/libusb/os
        ${LIBUSB_ROOT}/android
    PUBLIC
        $<BUILD_INTERFACE:${LIBUSB_ROOT}/libusb>
        $<INSTALL_INTERFACE:include>
)

target_compile_definitions(libusb100_static PRIVATE
    ANDROID_NDK
    LOG_NDEBUG
    ACCESS_RAW_DESCRIPTORS
)

target_compile_options(libusb100_static PRIVATE
    -O3
    -fstrict-aliasing
    -fprefetch-loop-arrays
)

# =============================================================================
# Shared Library
# =============================================================================

add_library(libusb100 SHARED)

target_link_libraries(libusb100 PRIVATE
    $<LINK_LIBRARY:WHOLE_ARCHIVE,libusb100_static>
    log
)
```

---

## 4. libuvc CMakeLists.txt

```cmake
# =============================================================================
# libuvc/android/jni/CMakeLists.txt
# =============================================================================

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

# =============================================================================
# Static Library
# =============================================================================

add_library(libuvc_static STATIC ${LIBUVC_SOURCES})

target_include_directories(libuvc_static
    PRIVATE
        ${LIBUVC_ROOT}
    PUBLIC
        $<BUILD_INTERFACE:${LIBUVC_ROOT}/include>
        $<BUILD_INTERFACE:${LIBUVC_ROOT}/include/libuvc>
        $<INSTALL_INTERFACE:include>
)

target_compile_definitions(libuvc_static PRIVATE
    ANDROID_NDK
    LOG_NDEBUG
    UVC_DEBUGGING
)

# Dependencies (PUBLIC for header inclusion)
target_link_libraries(libuvc_static PUBLIC
    jpeg-turbo1500
    libusb100
)

# =============================================================================
# Shared Library
# =============================================================================

add_library(uvc SHARED)

target_link_libraries(uvc PRIVATE
    $<LINK_LIBRARY:WHOLE_ARCHIVE,libuvc_static>
    log
)
```

---

## 5. UVCCamera CMakeLists.txt

```cmake
# =============================================================================
# UVCCamera/CMakeLists.txt
# =============================================================================

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

# =============================================================================
# Main Shared Library
# =============================================================================

add_library(UVCCamera SHARED ${UVCCAMERA_SOURCES})

target_include_directories(UVCCamera PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../
    ${CMAKE_CURRENT_SOURCE_DIR}/../rapidjson/include
)

target_compile_definitions(UVCCamera PRIVATE
    ANDROID_NDK
    LOG_NDEBUG
    ACCESS_RAW_DESCRIPTORS
)

target_compile_options(UVCCamera PRIVATE
    -O3
    -fstrict-aliasing
    -fprefetch-loop-arrays
)

# =============================================================================
# Dependencies
# =============================================================================

target_link_libraries(UVCCamera PRIVATE
    # Project libraries
    libusb100
    uvc
    jpeg-turbo1500_static  # Static link for JPEG encoding

    # Android system libraries
    android
    log
    nativewindow
    EGL
    GLESv2
    dl
)

# =============================================================================
# JNI Symbol Visibility
# =============================================================================

# Ensure JNI symbols are exported
set_target_properties(UVCCamera PROPERTIES
    # Default visibility hidden, explicit exports via JNI_EXPORT
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)
```

---

## 6. Gradle Integration

```groovy
// lib/build.gradle

android {
    namespace 'com.serenegiant.usb'
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

    buildTypes {
        release {
            minifyEnabled false
        }
        debug {
            jniDebuggable true
        }
    }
}
```

---

## 7. Build Commands

### Command Line Build

```bash
# Set NDK path
export ANDROID_NDK=/path/to/android-ndk-r28

# Configure for arm64-v8a
cmake -B build-arm64 \
    -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-26 \
    -DANDROID_STL=c++_shared \
    -DCMAKE_BUILD_TYPE=Release

# Build
cmake --build build-arm64 --parallel

# Configure for armeabi-v7a
cmake -B build-armv7 \
    -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=armeabi-v7a \
    -DANDROID_PLATFORM=android-26 \
    -DANDROID_STL=c++_shared \
    -DCMAKE_BUILD_TYPE=Release

# Build
cmake --build build-armv7 --parallel
```

### Verification

```bash
# Check output files
ls -la build-arm64/*.so
ls -la build-armv7/*.so

# Verify symbols
nm -D build-arm64/libUVCCamera.so | grep Java_
readelf -d build-arm64/libUVCCamera.so | grep NEEDED
```

---

## 8. Verification Checklist

- [ ] All 4 shared libraries produced per ABI
- [ ] JNI_OnLoad symbol exported
- [ ] Java_* symbols exported
- [ ] 16KB page alignment verified
- [ ] Dependencies correctly linked
- [ ] Symbol visibility as expected

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **BUILD-001** | Module list |
| **BUILD-003** | Compiler flags |
| **BUILD-004** | Dependencies |
| **BUILD-009** | Migration strategy |

---

*End of BUILD-010*
