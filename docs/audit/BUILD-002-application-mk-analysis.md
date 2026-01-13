# BUILD-002: Application.mk Analysis

**Audit:** AUDIT-005 Build System Archaeology
**Generated:** 2026-01-11
**Target:** ndk-build Global Configuration

---

## Summary

| Setting | Primary Value | libusb Value | Status |
|---------|---------------|--------------|--------|
| APP_PLATFORM | android-26 | (inherited) | Review |
| APP_ABI | armeabi-v7a arm64-v8a | all | Active |
| APP_OPTIM | release | (inherited) | Active |
| APP_STL | c++_shared | (inherited) | Active |
| APP_LDFLAGS | 16KB page alignment | -llog | Active |

---

## 1. Primary Application.mk

**File:** `jni/Application.mk`

```makefile
# APP_PLATFORM sets minimum API level
APP_PLATFORM := android-26

# Target ABIs
APP_ABI := armeabi-v7a arm64-v8a

# Optimization level
APP_OPTIM := release

# C++ Standard Library
APP_STL := c++_shared

# 16 KB page size alignment for Android 15+ compatibility
APP_LDFLAGS := -Wl,-z,max-page-size=16384
```

### Setting Analysis

#### APP_PLATFORM := android-26

| Aspect | Value |
|--------|-------|
| API Level | 26 (Android 8.0 Oreo) |
| Minimum SDK | 26 |
| NDK Implication | Uses headers/libs from android-26 sysroot |

**Recommendation:** Consider updating to `android-34` for latest security features.

#### APP_ABI := armeabi-v7a arm64-v8a

| ABI | Architecture | Notes |
|-----|--------------|-------|
| armeabi-v7a | 32-bit ARM (v7a) | Legacy support |
| arm64-v8a | 64-bit ARM (AArch64) | Primary target |

**Missing ABIs:**
- `x86` - Android Studio emulator support
- `x86_64` - Android Studio emulator support (64-bit)
- `riscv64` - Experimental, NOT production ready

**Evidence from libjpeg-turbo/Android.mk:**
```makefile
ifeq ($(TARGET_ARCH_ABI),x86)
LOCAL_SRC_FILES += simd/jsimd_i386.c ...
```
libjpeg-turbo has SIMD support for x86/x86_64, but they're not built currently.

#### APP_OPTIM := release

| Mode | Compiler Flags |
|------|----------------|
| release | -O2 (default) |
| debug | -O0 -g |

**Note:** Individual modules override with `-O3` (see BUILD-003).

#### APP_STL := c++_shared

| STL | Description | Binary Impact |
|-----|-------------|---------------|
| c++_shared | libc++ shared library | Requires libc++_shared.so at runtime |
| c++_static | libc++ static library | Larger binaries, no runtime dependency |
| none | No C++ standard library | Pure C compatibility |

**Rationale (from comment):**
> "Use c++_shared STL for std::mutex, std::condition_variable, etc.
> Required for Phase 2 WARM state surface swap handshake"

**Runtime Requirement:** `libc++_shared.so` must be packaged with the APK.

#### APP_LDFLAGS := -Wl,-z,max-page-size=16384

| Flag | Purpose |
|------|---------|
| -Wl,-z,max-page-size=16384 | 16 KB page alignment |

**Android 15+ Requirement:**
- Devices with 16 KB page sizes require aligned binaries
- Without this flag, app crashes on 16KB devices
- Reference: https://developer.android.com/guide/practices/page-sizes

**Status:** Correctly configured for forward compatibility.

---

## 2. Secondary Application.mk (libusb)

**File:** `jni/libusb/android/jni/Application.mk`

```makefile
APP_ABI := all

# Workaround for MIPS toolchain linker being unable to find liblog
APP_LDFLAGS := -llog
```

### Analysis

| Setting | Implication |
|---------|-------------|
| APP_ABI := all | Build for ALL supported ABIs |
| APP_LDFLAGS := -llog | Link liblog for all targets |

**Conflict:** This file is NOT used when building from the parent directory. The primary `jni/Application.mk` takes precedence.

**Evidence:** libusb can be built standalone from `libusb/android/jni/` but in the UVCCamera project, it inherits the parent Application.mk settings.

---

## 3. NDK Variable Reference

### Variables Used in Project

| Variable | Setting | Description |
|----------|---------|-------------|
| APP_PLATFORM | android-26 | Minimum API level |
| APP_ABI | armeabi-v7a arm64-v8a | Target architectures |
| APP_OPTIM | release | Optimization mode |
| APP_STL | c++_shared | C++ standard library |
| APP_LDFLAGS | 16KB alignment | Linker flags |

### Variables NOT Used (Defaults Apply)

| Variable | Default | Notes |
|----------|---------|-------|
| APP_CFLAGS | (none) | Would add flags to all modules |
| APP_CPPFLAGS | (none) | C++ specific flags |
| APP_ASMFLAGS | (none) | Assembly flags |
| APP_BUILD_SCRIPT | Android.mk | Build script path |
| APP_PROJECT_PATH | (auto) | Project root |
| APP_SHORT_COMMANDS | false | Use response files |
| APP_STRIP_MODE | default | Strip debug symbols |
| APP_THIN_ARCHIVE | true | Use thin archives |

---

## 4. STL Analysis

### c++_shared Selection Rationale

The project requires modern C++ features:

**Required Features:**
1. `std::mutex` - Thread synchronization
2. `std::condition_variable` - Producer/consumer patterns
3. `std::atomic` - Lock-free operations
4. `std::thread` - Thread management

**Evidence from code:**
```cpp
// HandleManager.h
std::atomic<uint32_t> generation{0};
std::atomic<int> activeRefs{0};
std::atomic<ContextPtr> context{0};

// UVCPreview.cpp
std::mutex frameLock;
std::condition_variable frameCV;
```

### STL Runtime Consideration

| Item | Implication |
|------|-------------|
| APK Size | +~300KB for libc++_shared.so |
| Compatibility | All modules must use same STL |
| JNI Loading | System.loadLibrary loads dependency first |

---

## 5. ABI Configuration Impact

### Current Configuration: armeabi-v7a + arm64-v8a

**Coverage:**
- arm64-v8a: 90%+ of active Android devices (2024+)
- armeabi-v7a: Legacy device support

**Missing:**
- x86/x86_64: Emulator support only
- riscv64: NOT production ready (experimental in NDK r28+)

### SIMD Support by ABI

| ABI | SIMD Available | libjpeg-turbo Status |
|-----|----------------|---------------------|
| arm64-v8a | NEON (mandatory) | Enabled |
| armeabi-v7a | NEON (optional) | Available, not enabled |
| x86_64 | SSE/AVX | Code present, not built |
| x86 | SSE/MMX/3DNow | Code present, not built |

**Note:** armeabi-v7a NEON is commented out in Android.mk:
```makefile
#LOCAL_ARM_NEON := true
LOCAL_SRC_FILES += simd/jsimd_arm.c simd/jsimd_arm_neon.S
```

---

## 6. Page Size Compatibility

### Android 15+ 16KB Page Size Requirement

**Problem:** Android 15 introduces devices with 16KB page sizes. Binaries with 4KB alignment crash.

**Solution Applied:**
```makefile
APP_LDFLAGS := -Wl,-z,max-page-size=16384
```

**Verification Required:**
All shared libraries must be built with this flag:
- libUVCCamera.so
- libjpeg-turbo1500.so
- libusb100.so
- libuvc.so

**Cross-reference:** BUILD-006 Security Flag Verification

---

## 7. Recommended Updates

### API Level Update (android-26 → android-34)

| Benefit | android-34 |
|---------|------------|
| Security hardening | Latest SELinux policies |
| NDK features | Full JNI symbol checking |
| ABI stability | Stable NNAPI, etc. |

**Migration:**
```makefile
# Current
APP_PLATFORM := android-26

# Recommended
APP_PLATFORM := android-34
```

**Note:** This only affects NDK build. minSdkVersion in build.gradle remains separate.

### Emulator Support (Optional)

```makefile
# Add x86_64 for emulator testing
APP_ABI := armeabi-v7a arm64-v8a x86_64
```

### NEON Enablement (armeabi-v7a)

```makefile
# In libjpeg-turbo Android.mk, line 129-130
ifeq ($(TARGET_ARCH_ABI),armeabi-v7a)
LOCAL_ARM_NEON := true  # Uncomment for NEON on v7a
```

**Trade-off:** Drops support for pre-NEON ARMv7 devices (rare in 2024+).

---

## 8. Configuration Matrix

### Effective Configuration per Build

| Setting | Standalone libusb Build | Full UVCCamera Build |
|---------|------------------------|----------------------|
| APP_PLATFORM | android-26 | android-26 |
| APP_ABI | all | armeabi-v7a arm64-v8a |
| APP_OPTIM | release | release |
| APP_STL | c++_shared | c++_shared |
| APP_LDFLAGS | -llog | -Wl,-z,max-page-size=16384 |

---

## 9. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| APP-001 | Medium | APP_PLATFORM=android-26 is dated | Update to android-34 |
| APP-002 | Low | Missing x86_64 for emulator | Add if emulator testing needed |
| APP-003 | Info | armeabi-v7a NEON disabled | Enable for performance |
| APP-004 | Info | Conflicting libusb Application.mk | Document inheritance |

### Positive Findings

| ID | Finding | Status |
|----|---------|--------|
| APP-P01 | 16KB page alignment configured | Correct |
| APP-P02 | c++_shared for modern C++ features | Correct |
| APP-P03 | arm64-v8a as primary target | Correct |
| APP-P04 | release optimization mode | Correct |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **BUILD-001** | Android.mk inventory |
| **BUILD-003** | Compiler flag extraction |
| **BUILD-006** | Security flag verification |
| **BUILD-007** | ABI configuration analysis |

---

*End of BUILD-002*
