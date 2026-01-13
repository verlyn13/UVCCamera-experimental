# FEASIBILITY-007: Build System Migration

**Status:** Complete
**Date:** 2026-01-11
**Author:** Claude
**Depends On:** None (standalone infrastructure assessment)

---

## Executive Summary

The current build system uses **ndk-build (Android.mk/Application.mk)**, which is fully functional but increasingly considered legacy. Migration to **CMake** is technically feasible but carries **moderate risk and limited benefit** for this project. The assembly-heavy libjpeg-turbo dependency is the primary complexity factor.

**Key Finding:** The current ndk-build setup is **well-maintained and working**. Migration effort would be significant with limited immediate benefit.

**Recommendation:** **DEFER** - Keep ndk-build for now, monitor for AGP deprecation signals. Migration is feasible when forced but not urgent.

---

## 1. Current State Analysis

### 1.1 Build System Inventory

| File | Purpose | Lines |
|------|---------|-------|
| `jni/Android.mk` | Root orchestration | 7 |
| `jni/Application.mk` | NDK settings | 41 |
| `jni/UVCCamera/Android.mk` | Main library | 79 |
| `jni/libuvc/android/jni/Android.mk` | UVC library | 88 |
| `jni/libusb/android/jni/libusb.mk` | USB library | 77 |
| `jni/libjpeg-turbo-1.5.0/Android.mk` | JPEG library | 269 |
| **Total** | | **~561 lines** |

### 1.2 Build Hierarchy

```
lib/build.gradle.kts
    └── externalNativeBuild.ndkBuild.path = "src/main/jni/Android.mk"
            │
            ├── UVCCamera/Android.mk
            │       └── libUVCCamera.so (links usb100, uvc, jpeg-turbo1500)
            │
            ├── libuvc/android/jni/Android.mk
            │       └── libuvc_static.a → libuvc.so
            │
            ├── libusb/android/jni/Android.mk
            │       └── libusb100_static.a → libusb100.so
            │
            └── libjpeg-turbo-1.5.0/Android.mk
                    └── jpeg-turbo1500_static.a → libjpeg-turbo1500.so
```

### 1.3 Key Configuration Details

**Application.mk (Global NDK Settings):**
```makefile
APP_PLATFORM := android-26          # API level 26 minimum
APP_ABI := armeabi-v7a arm64-v8a    # 32-bit and 64-bit ARM
APP_STL := c++_shared               # C++ standard library
APP_LDFLAGS := -Wl,-z,max-page-size=16384  # Android 15+ page alignment
```

**Shared Libraries Produced:**
- `libUVCCamera.so` - Main JNI interface
- `libuvc.so` - UVC protocol implementation
- `libusb100.so` - USB communication
- `libjpeg-turbo1500.so` - JPEG encoding/decoding

### 1.4 Complexity Factors

#### 1.4.1 libjpeg-turbo Assembly (HIGH Complexity)

**269 lines of architecture-specific configuration:**

| ABI | Sources |
|-----|---------|
| armeabi-v7a | `jsimd_arm.c`, `jsimd_arm_neon.S` (ARM NEON) |
| arm64-v8a | `jsimd_arm64.c`, `jsimd_arm64_neon.S` |
| x86 | 26 `.asm` files (MMX, 3DNow, SSE, SSE2) |
| x86_64 | 13 `.asm` files (SSE, SSE2) |
| mips | `jsimd_mips.c`, `jsimd_mips_dspr2.S` |
| Fallback | `jsimd_none.c` (no SIMD) |

This is the most complex part of any migration effort.

#### 1.4.2 libusb Android-Specific Files (MEDIUM Complexity)

Modified source files for Android:
- `libusb/os/android_usbfs.c` (vs. `linux_usbfs.c`)
- `libusb/os/android_netlink.c` (vs. `linux_netlink.c`)

These are Android-specific rewrites, not just build system changes.

#### 1.4.3 libuvc Fork Modifications (LOW Complexity)

Uses standard source list:
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

No architecture-specific code.

### 1.5 Existing CMake Files

| Location | Purpose | Usable for Android? |
|----------|---------|---------------------|
| `libuvc/CMakeLists.txt` | Upstream build | **No** - desktop-oriented |
| `libjpeg-turbo-1.5.0/CMakeLists.txt` | Upstream build | **No** - different assembly approach |
| `test/CMakeLists.txt` | Host testing | **Yes** - Google Test setup |

---

## 2. Target State Options

### 2.1 Option A: Stay with ndk-build

**Configuration:**
```kotlin
// lib/build.gradle.kts (current)
externalNativeBuild {
    ndkBuild {
        path = file("src/main/jni/Android.mk")
    }
}
```

**Advantages:**
- Zero migration effort
- Working, tested configuration
- All architecture-specific assembly handled
- No regression risk

**Disadvantages:**
- Considered "legacy" by Google
- Less IDE support for code navigation
- May eventually be deprecated

### 2.2 Option B: Full CMake Migration

**Configuration:**
```kotlin
// lib/build.gradle.kts (proposed)
externalNativeBuild {
    cmake {
        path = file("src/main/jni/CMakeLists.txt")
        version = "3.22.1"
    }
}
```

**Required New Files:**
- `jni/CMakeLists.txt` (root)
- `jni/UVCCamera/CMakeLists.txt`
- `jni/libuvc/android/CMakeLists.txt` (Android-specific)
- `jni/libusb/android/CMakeLists.txt` (Android-specific)
- `jni/libjpeg-turbo-1.5.0/CMakeListsAndroid.txt` (Android-specific)

**Advantages:**
- Modern, recommended by Google
- Better IDE integration (code completion, navigation)
- Consistent with test infrastructure
- Better dependency tracking

**Disadvantages:**
- 2-3 weeks of migration effort
- High regression risk during transition
- Complex libjpeg-turbo assembly handling
- Need to maintain Android-specific CMake alongside upstream

### 2.3 Option C: Hybrid (Incremental Migration)

Migrate component by component:
1. Keep libjpeg-turbo on ndk-build (most complex)
2. Migrate libuvc to CMake
3. Migrate libusb to CMake
4. Migrate UVCCamera to CMake

**Configuration:**
```kotlin
// This is NOT supported by AGP
// Cannot mix ndkBuild and cmake in same module
```

**Status:** Not possible - AGP requires single build system per module.

---

## 3. CMake Migration Details (If Pursued)

### 3.1 Root CMakeLists.txt

```cmake
cmake_minimum_required(VERSION 3.22)
project(UVCCamera LANGUAGES C CXX ASM)

# Android toolchain provides these
# - ANDROID_ABI, ANDROID_PLATFORM, ANDROID_STL

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

# Page alignment for Android 15+
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")

# Sub-projects
add_subdirectory(libjpeg-turbo-1.5.0)
add_subdirectory(libusb/android)
add_subdirectory(libuvc/android)
add_subdirectory(UVCCamera)
```

### 3.2 libjpeg-turbo Challenge

The libjpeg-turbo Android.mk uses **YASM assembler** for x86/x86_64 and **GNU assembler** for ARM. CMake handling:

```cmake
# Simplified - actual would be much more complex
if(ANDROID_ABI STREQUAL "armeabi-v7a" OR ANDROID_ABI STREQUAL "arm64-v8a")
    # ARM NEON assembly (GNU assembler)
    enable_language(ASM)
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        set(JPEG_SIMD_SOURCES
            simd/jsimd_arm64.c
            simd/jsimd_arm64_neon.S
        )
    else()
        set(JPEG_SIMD_SOURCES
            simd/jsimd_arm.c
            simd/jsimd_arm_neon.S
        )
    endif()
elseif(ANDROID_ABI STREQUAL "x86" OR ANDROID_ABI STREQUAL "x86_64")
    # x86 NASM/YASM assembly - complex setup required
    # Would need to find and enable NASM
    # Different file lists for 32 vs 64 bit
    # Many .asm files with specific flags
    # ...
else()
    # Fallback
    set(JPEG_SIMD_SOURCES jsimd_none.c)
endif()
```

**Complexity:** ~200-300 lines of CMake for proper libjpeg-turbo SIMD handling.

### 3.3 libusb CMake

```cmake
# libusb/android/CMakeLists.txt
set(LIBUSB_SOURCES
    ../libusb/core.c
    ../libusb/descriptor.c
    ../libusb/hotplug.c
    ../libusb/io.c
    ../libusb/sync.c
    ../libusb/strerror.c
    # Android-specific
    ../libusb/os/android_usbfs.c
    ../libusb/os/poll_posix.c
    ../libusb/os/threads_posix.c
    ../libusb/os/android_netlink.c
)

add_library(usb100 SHARED ${LIBUSB_SOURCES})
target_include_directories(usb100 PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/..
    ${CMAKE_CURRENT_SOURCE_DIR}/../libusb
)
target_compile_definitions(usb100 PRIVATE
    ANDROID_NDK
    LOG_NDEBUG
    ACCESS_RAW_DESCRIPTORS
)
target_link_libraries(usb100 log)
```

**Complexity:** ~50-80 lines of CMake.

### 3.4 libuvc CMake

```cmake
# libuvc/android/CMakeLists.txt
set(LIBUVC_SOURCES
    ../src/ctrl.c
    ../src/device.c
    ../src/diag.c
    ../src/frame.c
    ../src/frame-mjpeg.c
    ../src/init.c
    ../src/stream.c
)

add_library(uvc SHARED ${LIBUVC_SOURCES})
target_include_directories(uvc PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
)
target_compile_definitions(uvc PRIVATE
    ANDROID_NDK
    LOG_NDEBUG
    UVC_DEBUGGING
)
target_link_libraries(uvc jpeg-turbo1500 usb100 log)
```

**Complexity:** ~40-60 lines of CMake.

### 3.5 UVCCamera CMake

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
target_link_libraries(UVCCamera
    uvc
    usb100
    jpeg-turbo1500_static
    log
    android
    nativewindow
    EGL
    GLESv2
)
```

**Complexity:** ~60-80 lines of CMake.

---

## 4. Risk Assessment

### 4.1 Migration Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| SIMD assembly breaks | HIGH | HIGH | Extensive testing per ABI |
| Build time regression | MEDIUM | LOW | Benchmark before/after |
| IDE issues | LOW | LOW | Test Android Studio |
| AGP compatibility | LOW | MEDIUM | Test with multiple AGP versions |
| CI/CD breaks | MEDIUM | MEDIUM | Parallel testing during migration |

### 4.2 Not Migrating Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| ndk-build deprecation | LOW (short term) | HIGH | Monitor AGP release notes |
| Missing IDE features | ONGOING | LOW | Acceptable tradeoff |
| Documentation outdated | LOW | LOW | Community still uses ndk-build |

### 4.3 AGP ndk-build Support Status

| AGP Version | ndk-build Support | Notes |
|-------------|-------------------|-------|
| 4.x | Full | |
| 7.x | Full | |
| 8.x | Full | Current |
| 8.5+ | Full | No deprecation announced |

**Google's position:** CMake is "recommended" but ndk-build is "supported". No deprecation timeline announced as of 2025.

---

## 5. Effort Estimation

### 5.1 Full CMake Migration

| Component | LOC (CMake) | Effort |
|-----------|-------------|--------|
| Root CMakeLists.txt | 50 | 2-4 hours |
| libjpeg-turbo | 300 | 3-5 days |
| libusb | 80 | 1-2 days |
| libuvc | 60 | 1 day |
| UVCCamera | 80 | 1-2 days |
| Testing all ABIs | - | 3-5 days |
| CI/CD updates | - | 1-2 days |
| Documentation | - | 1 day |
| **Total** | ~570 | **10-17 days** |

### 5.2 Maintaining Both (If Hybrid Were Possible)

Not recommended - double maintenance burden with no benefit.

### 5.3 Keeping ndk-build

| Task | Effort |
|------|--------|
| Nothing required | 0 |
| Occasional updates | Minimal |

---

## 6. Comparison: ndk-build vs CMake

| Aspect | ndk-build | CMake |
|--------|-----------|-------|
| **Syntax** | Makefile-like | CMake language |
| **Android Support** | Native | Via toolchain file |
| **IDE Integration** | Basic | Full (navigation, completion) |
| **Documentation** | Extensive legacy | Modern, recommended |
| **Assembly Handling** | Mature (YASM, GAS) | Complex setup |
| **Google Preference** | "Supported" | "Recommended" |
| **Community Usage** | ~40% | ~60% |
| **Learning Curve** | Already known | New syntax |
| **Debugging** | OK | Better |

---

## 7. Alternative Approaches

### 7.1 Pre-built Dependencies

Instead of building libjpeg-turbo from source:
- Use AAR dependency for libjpeg-turbo
- Reduces build complexity significantly

**Challenge:** No standard Android AAR for libjpeg-turbo exists.

### 7.2 Modernize libjpeg-turbo Version

Current version: **1.5.0** (released 2016)
Latest version: **3.x** (2024)

**Benefits:**
- Modern CMake support
- Better Android support
- Performance improvements

**Risks:**
- API changes
- Testing effort

### 7.3 Consider libpng-based Alternative

For some use cases, PNG might suffice:
- Android has libpng built-in
- No assembly complexity

**Not applicable:** MJPEG requires JPEG, not PNG.

---

## 8. Recommendation

### 8.1 Decision: **DEFER**

**Rationale:**
1. Current ndk-build is **working and maintained**
2. No AGP deprecation announced
3. Migration effort is **2-3 weeks with risk**
4. Benefits are primarily cosmetic (IDE support)
5. Assembly complexity makes migration non-trivial

### 8.2 When to Reconsider

Migration should be triggered by:
1. **AGP deprecation announcement** for ndk-build
2. **New developer onboarding** issues with ndk-build
3. **Major restructuring** of native code (e.g., after FEASIBILITY-006)
4. **libjpeg-turbo upgrade** to 3.x (better CMake support)

### 8.3 If Migration Becomes Necessary

**Recommended approach:**
1. Upgrade libjpeg-turbo to 3.x first (better CMake)
2. Create CMake alongside ndk-build temporarily
3. Validate all ABIs extensively
4. Remove ndk-build only after production validation

### 8.4 Immediate Improvements (Without Migration)

If build system improvements are desired:

1. **Add compilation database** for IDE features:
   ```bash
   ndk-build -C jni V=1 -n | compiledb
   ```

2. **Add ninja generator** for faster builds (if needed):
   ```makefile
   # Already possible with APP_BUILD_SCRIPT
   ```

3. **Improve logging** in Android.mk for debugging

---

## Appendix A: AGP externalNativeBuild Reference

### A.1 ndk-build Configuration

```kotlin
android {
    externalNativeBuild {
        ndkBuild {
            path = file("src/main/jni/Android.mk")
        }
    }
    defaultConfig {
        externalNativeBuild {
            ndkBuild {
                abiFilters += listOf("armeabi-v7a", "arm64-v8a")
                arguments += listOf(
                    "APP_STL=c++_shared",
                    "NDK_DEBUG=0"
                )
            }
        }
    }
}
```

### A.2 CMake Configuration

```kotlin
android {
    externalNativeBuild {
        cmake {
            path = file("src/main/jni/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    defaultConfig {
        externalNativeBuild {
            cmake {
                abiFilters += listOf("armeabi-v7a", "arm64-v8a")
                cppFlags += listOf("-std=c++17")
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DANDROID_TOOLCHAIN=clang"
                )
            }
        }
    }
}
```

---

## Appendix B: libjpeg-turbo Assembly Files

### B.1 ARM (armeabi-v7a)

```
simd/jsimd_arm.c          - C wrapper
simd/jsimd_arm_neon.S     - NEON assembly
```

### B.2 ARM64 (arm64-v8a)

```
simd/jsimd_arm64.c        - C wrapper
simd/jsimd_arm64_neon.S   - NEON assembly
```

### B.3 x86

```
simd/jsimd_i386.c         - C wrapper
simd/jsimdcpu.asm         - CPU detection
simd/jfdctflt-3dn.asm     - 3DNow! DCT
simd/jidctflt-3dn.asm     - 3DNow! IDCT
simd/jquant-3dn.asm       - 3DNow! quantization
simd/jccolor-mmx.asm      - MMX color conversion
... (20+ more .asm files)
```

### B.4 x86_64

```
simd/jsimd_x86_64.c       - C wrapper
simd/jccolor-sse2-64.asm  - SSE2 color conversion
simd/jfdctint-sse2-64.asm - SSE2 DCT
... (12 more .asm files)
```

---

## Appendix C: Test Infrastructure CMake

The project already has CMake-based testing (`test/CMakeLists.txt`):

```cmake
cmake_minimum_required(VERSION 3.22)
project(uvccamera-native-tests)

enable_testing()

# Google Test via FetchContent
include(FetchContent)
FetchContent_Declare(googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG v1.14.0
)
FetchContent_MakeAvailable(googletest)

add_executable(native_tests
    ${PRODUCTION_SRC}/FrameBufferRing.cpp
    tests/ContractTest.cpp
    tests/StreamTelemetryTest.cpp
    tests/FrameBufferRingTest.cpp
    mocks/AndroidApiMocks.cpp
)

target_link_libraries(native_tests
    GTest::gtest_main
    GTest::gmock
)

gtest_discover_tests(native_tests)
```

This demonstrates CMake capability exists in the project for host-side testing, separate from Android build.

---

*End of FEASIBILITY-007*
