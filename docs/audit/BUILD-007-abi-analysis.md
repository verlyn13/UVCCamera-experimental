# BUILD-007: ABI Configuration Analysis

**Audit:** AUDIT-005 Build System Archaeology
**Generated:** 2026-01-11
**Target:** Application Binary Interface Analysis

---

## Summary

| Metric | Value |
|--------|-------|
| Active ABIs | 2 |
| Device coverage | ~99% |
| Binary outputs | 4 shared + 4 static per ABI |
| STL | c++_shared |

---

## 1. Active ABI Configuration

### From Application.mk

```makefile
APP_ABI := armeabi-v7a arm64-v8a
```

### ABI Details

| ABI | Architecture | Instruction Set | CPU Features |
|-----|--------------|-----------------|--------------|
| armeabi-v7a | ARMv7-A | ARM/Thumb-2 | VFPv3-D16, Optional NEON |
| arm64-v8a | ARMv8-A | AArch64 | NEON (mandatory), CRC32 |

---

## 2. armeabi-v7a Configuration

### Architecture Details

| Property | Value |
|----------|-------|
| Pointer size | 32-bit |
| Endianness | Little |
| Minimum CPU | Cortex-A8 |
| NDK Triple | armv7a-linux-androideabi |

### Compiler Settings

| Setting | Value | Source |
|---------|-------|--------|
| Float ABI | softfp | NDK default |
| FPU | VFPv3-D16 | NDK default |
| ARM Mode | arm | LOCAL_ARM_MODE |
| NEON | Runtime detection | Not forced |

### Float ABI Clarification

**IMPORTANT:** `-mfloat-abi=softfp` is CORRECT for Android.

| ABI | Description | Android Status |
|-----|-------------|----------------|
| soft | All FP in software | Not used |
| softfp | Hardware FP, software calling convention | **Standard** |
| hard | Hardware FP, hardware calling convention | Not supported |

**Why softfp?**
- Allows mixing code compiled with different FPU options
- System libraries use softfp calling convention
- Does NOT mean "software floating point" - hardware FPU is used

### NEON Support

```makefile
# In libjpeg-turbo Android.mk:
#LOCAL_ARM_NEON := true  # Commented out
LOCAL_SRC_FILES += simd/jsimd_arm.c simd/jsimd_arm_neon.S
```

**Current Behavior:**
- NEON code is compiled
- Runtime detection determines if NEON is used
- Safe for devices without NEON (rare in 2024+)

**Recommendation:**
- Enable `LOCAL_ARM_NEON := true` for all modules
- All armeabi-v7a devices since 2012 have NEON
- Non-NEON devices are effectively extinct

---

## 3. arm64-v8a Configuration

### Architecture Details

| Property | Value |
|----------|-------|
| Pointer size | 64-bit |
| Endianness | Little |
| Minimum CPU | Cortex-A53 |
| NDK Triple | aarch64-linux-android |

### Compiler Settings

| Setting | Value | Source |
|---------|-------|--------|
| Float ABI | N/A | 64-bit has different ABI |
| SIMD | NEON (mandatory) | Always available |
| ARM Mode | N/A | Only 64-bit mode |

### Feature Availability

| Feature | Status | Notes |
|---------|--------|-------|
| NEON | Mandatory | All arm64 has NEON |
| CRC32 | Optional | Most modern CPUs |
| AES/SHA | Optional | Crypto acceleration |
| MTE | Optional | ARMv8.5-A+ only |

---

## 4. Binary Output Analysis

### Expected Output Structure

```
lib/
├── armeabi-v7a/
│   ├── libUVCCamera.so
│   ├── libjpeg-turbo1500.so
│   ├── libusb100.so
│   ├── libuvc.so
│   └── libc++_shared.so
└── arm64-v8a/
    ├── libUVCCamera.so
    ├── libjpeg-turbo1500.so
    ├── libusb100.so
    ├── libuvc.so
    └── libc++_shared.so
```

### Size Estimates

| Library | armeabi-v7a | arm64-v8a | Notes |
|---------|-------------|-----------|-------|
| libUVCCamera.so | ~800 KB | ~1.2 MB | Main library |
| libjpeg-turbo1500.so | ~450 KB | ~500 KB | SIMD-heavy |
| libusb100.so | ~200 KB | ~250 KB | USB handling |
| libuvc.so | ~150 KB | ~180 KB | UVC protocol |
| libc++_shared.so | ~300 KB | ~350 KB | STL runtime |
| **Total** | ~1.9 MB | ~2.5 MB | Per ABI |

---

## 5. ABI-Specific Code Paths

### Source File Selection

| ABI | libjpeg-turbo SIMD | SIZEOF_SIZE_T |
|-----|-------------------|---------------|
| armeabi-v7a | jsimd_arm.c, jsimd_arm_neon.S | 4 |
| arm64-v8a | jsimd_arm64.c, jsimd_arm64_neon.S | 8 |

### Code Impact

```c
// Size-dependent code in libjpeg-turbo
#if SIZEOF_SIZE_T == 8
    // 64-bit optimized loops
    for (size_t i = 0; i < count; i += 8) { ... }
#else
    // 32-bit loops
    for (size_t i = 0; i < count; i += 4) { ... }
#endif
```

---

## 6. Missing ABIs Analysis

### x86 / x86_64 (Emulator Support)

**Current Status:** Not built

**Impact:**
- Cannot run on Android Studio emulator efficiently
- ARM translation layer (QEMU) is slow
- Debug cycle longer

**Recommendation:**
```makefile
# For development builds
APP_ABI := armeabi-v7a arm64-v8a x86_64
```

### riscv64 (Experimental)

**Current Status:** Not in NDK stable

**NDK Status:**
- NDK r28+: Experimental support
- NOT a shipping ABI
- No production devices

**Recommendation:** Do not add riscv64 until NDK declares it stable.

---

## 7. LOCAL_ARM_MODE Analysis

### Current Settings

All modules use:
```makefile
LOCAL_ARM_MODE := arm
```

### Mode Comparison

| Mode | Instruction Width | Code Density | Performance |
|------|------------------|--------------|-------------|
| arm | 32-bit | Lower | Slightly better |
| thumb | 16/32-bit | Higher | Similar |

### Trade-off Analysis

| Factor | arm Mode | thumb Mode |
|--------|----------|------------|
| Binary size | Larger | 25-30% smaller |
| Cache usage | More | Less |
| Branch prediction | Better | Similar |
| Performance | Marginal gain | Baseline |

**Recommendation:** Keep `arm` mode for performance-critical code. Consider `thumb` for UVCStatusCallback, UVCButtonCallback (infrequently called).

---

## 8. STL Configuration

### Current Setting

```makefile
APP_STL := c++_shared
```

### STL Options

| STL | Pros | Cons |
|-----|------|------|
| c++_shared | Smaller per-library | Requires runtime library |
| c++_static | Self-contained | Each library has full STL |
| none | Smallest | No C++ standard library |

### C++ Features Used

```cpp
// In project code
#include <atomic>      // std::atomic
#include <mutex>       // std::mutex
#include <thread>      // std::thread
#include <memory>      // std::unique_ptr
#include <vector>      // std::vector
#include <condition_variable>  // std::condition_variable
```

**Verdict:** `c++_shared` is correct choice. Static would duplicate ~300KB per library.

---

## 9. API Level Impact

### Current: android-26

| API | ABI Impact |
|-----|------------|
| 26+ | Required for certain system calls |
| 26 | Oreo - broad device support |

### Minimum API by ABI

| ABI | Minimum Supported API |
|-----|----------------------|
| armeabi-v7a | 16 |
| arm64-v8a | 21 |
| x86 | 16 |
| x86_64 | 21 |

**Note:** arm64-v8a requires API 21 minimum (Android 5.0).

---

## 10. CMake ABI Configuration

### Equivalent CMake

```cmake
# In android.toolchain.cmake integration
set(ANDROID_ABI "arm64-v8a" CACHE STRING "Target ABI")
set_property(CACHE ANDROID_ABI PROPERTY STRINGS
    armeabi-v7a
    arm64-v8a
    x86
    x86_64
)

# ABI-specific configuration
if(ANDROID_ABI STREQUAL "armeabi-v7a")
    set(CMAKE_ANDROID_ARM_MODE arm)  # or thumb
    # NEON is optional but recommended
    set(CMAKE_ANDROID_ARM_NEON TRUE)

elseif(ANDROID_ABI STREQUAL "arm64-v8a")
    # NEON is mandatory, no configuration needed
    # MTE requires explicit opt-in:
    # set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=armv8.5-a+memtag")
endif()

# For multi-ABI builds
if(NOT DEFINED ANDROID_ABI)
    message(STATUS "Building for all ABIs")
    # CMake doesn't support multi-ABI in single invocation
    # Use Gradle for multi-ABI builds
endif()
```

---

## 11. Device Coverage Analysis

### Market Share (2024 Estimates)

| ABI | Device Share | Trend |
|-----|--------------|-------|
| arm64-v8a | ~90% | Increasing |
| armeabi-v7a | ~9% | Decreasing |
| x86/x86_64 | <1% | Emulator only |

### Supported Devices

**arm64-v8a (Primary):**
- All Pixel phones (3+)
- All Samsung Galaxy (S8+)
- All modern Qualcomm/MediaTek devices
- All iPads via Mac Catalyst (hypothetical)

**armeabi-v7a (Legacy):**
- Budget phones from 2015-2018
- Some IoT devices
- Android TV boxes

---

## 12. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| ABI-001 | Low | x86_64 not built | Add for emulator testing |
| ABI-002 | Info | armeabi-v7a NEON not forced | Enable LOCAL_ARM_NEON |
| ABI-003 | Info | arm mode increases binary size | Consider thumb for non-critical |
| ABI-004 | Info | riscv64 not supported | Correct - not stable |

### Positive Findings

| ID | Finding |
|----|---------|
| ABI-P01 | Both major ARM ABIs supported |
| ABI-P02 | c++_shared correct for multi-library |
| ABI-P03 | arm mode for performance-critical code |
| ABI-P04 | ABI-specific SIMD correctly configured |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **BUILD-002** | APP_ABI settings |
| **BUILD-005** | Platform-specific code |
| **BUILD-006** | ABI security implications |
| **BUILD-010** | CMake ABI handling |

---

*End of BUILD-007*
