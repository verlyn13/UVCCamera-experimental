# BUILD-005: Platform-Specific Configuration

**Audit:** AUDIT-005 Build System Archaeology
**Generated:** 2026-01-11
**Target:** ABI-Conditional Build Analysis

---

## Summary

| Metric | Count |
|--------|-------|
| ABI conditionals | 6 blocks |
| Active ABIs | 2 (armeabi-v7a, arm64-v8a) |
| Supported ABIs in code | 6 |
| SIMD implementations | 5 (ARM NEON, x86 SSE/MMX, x86_64 SSE) |

---

## 1. ABI Configuration Overview

### Active ABIs (from Application.mk)

```makefile
APP_ABI := armeabi-v7a arm64-v8a
```

| ABI | Status | Architecture | Pointer Size | Endianness |
|-----|--------|--------------|--------------|------------|
| armeabi-v7a | **Active** | ARM v7-A | 32-bit | Little |
| arm64-v8a | **Active** | ARM64 (AArch64) | 64-bit | Little |
| x86 | Code present | x86 (IA-32) | 32-bit | Little |
| x86_64 | Code present | x86-64 (AMD64) | 64-bit | Little |
| armeabi | Code present | ARM v5TE | 32-bit | Little |
| mips | Code present | MIPS32 | 32-bit | Little |

### Deprecated ABIs

| ABI | Removal NDK | Status in Project |
|-----|-------------|-------------------|
| armeabi | r17 | Code present, not built |
| mips | r17 | Code present, not built |
| mips64 | r17 | Not present |

---

## 2. libjpeg-turbo ABI Conditionals

### armeabi (ARM v5, deprecated)

```makefile
ifeq ($(TARGET_ARCH_ABI),armeabi)
LOCAL_SRC_FILES += simd/jsimd_arm.c simd/jsimd_arm_neon.S
LOCAL_CFLAGS += -DSIZEOF_SIZE_T=4
```

**Status:** Code present but ABI not in APP_ABI. Will not be built.

### armeabi-v7a (32-bit ARM)

```makefile
else ifeq ($(TARGET_ARCH_ABI),armeabi-v7a)
#LOCAL_ARM_NEON := true
LOCAL_SRC_FILES += simd/jsimd_arm.c simd/jsimd_arm_neon.S
LOCAL_CFLAGS += -DSIZEOF_SIZE_T=4
```

**Status:** Active. NEON commented out but SIMD sources included.

**Analysis:**
- SIMD assembly uses ARM NEON instructions
- `jsimd_arm.c` dispatches to NEON or C fallback at runtime
- NEON flag commented out; runtime detection used instead

### arm64-v8a (64-bit ARM)

```makefile
else ifeq ($(TARGET_ARCH_ABI),arm64-v8a)
#LOCAL_ARM_NEON := true
LOCAL_SRC_FILES += simd/jsimd_arm64.c simd/jsimd_arm64_neon.S
LOCAL_CFLAGS += -DSIZEOF_SIZE_T=8
```

**Status:** Active. NEON is mandatory on ARM64.

**Analysis:**
- Uses 64-bit NEON SIMD instructions
- `SIZEOF_SIZE_T=8` for 64-bit pointers
- All ARM64 devices have NEON, so SIMD always active

### x86_64

```makefile
else ifeq ($(TARGET_ARCH_ABI),x86_64)
LOCAL_SRC_FILES += \
    simd/jsimd_x86_64.c \
    simd/jfdctflt-sse-64.asm \
    simd/jccolor-sse2-64.asm \
    # ... 14 more .asm files
LOCAL_CFLAGS += -DSIZEOF_SIZE_T=8
LOCAL_ASMFLAGS += -D__x86_64__
```

**Status:** Code present but ABI not active.

**Analysis:**
- Full SSE2 SIMD implementation
- 17 assembly files for x86_64 optimizations
- Would enable fast emulator testing if activated

### x86 (32-bit)

```makefile
else ifeq ($(TARGET_ARCH_ABI),x86)
LOCAL_SRC_FILES += \
    simd/jsimd_i386.c \
    simd/jsimdcpu.asm \
    # ... 27 more .asm files (MMX, SSE, 3DNow)
LOCAL_CFLAGS += -DSIZEOF_SIZE_T=4
```

**Status:** Code present but ABI not active.

**Analysis:**
- Extensive x86 SIMD support (MMX, SSE, SSE2, 3DNow)
- 28 assembly files
- Most comprehensive SIMD coverage of any ABI

### mips (Deprecated)

```makefile
else ifeq ($(TARGET_ARCH_ABI),mips)
ifeq ($(NDK_TOOLCHAIN_VERSION),clang)
    LOCAL_SRC_FILES += jsimd_none.c  # MSA disabled
else
    LOCAL_SRC_FILES += simd/jsimd_mips.c simd/jsimd_mips_dspr2.S
endif
LOCAL_CFLAGS += -DSIZEOF_SIZE_T=4
```

**Status:** Deprecated, code present for reference only.

**Note:** Comment explains Clang MSA issues in NDK r13-r14.

### Default Fallback

```makefile
else
LOCAL_SRC_FILES += jsimd_none.c
endif
```

**Purpose:** Pure C fallback for unknown architectures.

---

## 3. SIMD Implementation Matrix

| ABI | SIMD Tech | Files | Performance |
|-----|-----------|-------|-------------|
| arm64-v8a | NEON (mandatory) | 2 | Excellent |
| armeabi-v7a | NEON (optional) | 2 | Good (when NEON available) |
| x86_64 | SSE2 | 17 | Excellent |
| x86 | MMX/SSE/SSE2/3DNow | 28 | Excellent |
| mips | DSPr2/MSA | 2 | Good (GCC only) |
| fallback | None (C code) | 1 | Baseline |

### SIMD File Counts

| ABI | Assembly Files | C Dispatcher | Total |
|-----|----------------|--------------|-------|
| arm64-v8a | 1 (.S) | 1 | 2 |
| armeabi-v7a | 1 (.S) | 1 | 2 |
| x86_64 | 16 (.asm) | 1 | 17 |
| x86 | 27 (.asm) | 1 | 28 |

---

## 4. Size and Performance Trade-offs

### SIZEOF_SIZE_T Configuration

| ABI | SIZEOF_SIZE_T | Implication |
|-----|---------------|-------------|
| arm64-v8a | 8 | 64-bit pointers, larger structs |
| armeabi-v7a | 4 | 32-bit pointers, smaller memory |
| x86_64 | 8 | 64-bit pointers |
| x86 | 4 | 32-bit pointers |

**Usage in libjpeg-turbo:**
```c
#if SIZEOF_SIZE_T == 8
    // 64-bit optimized code paths
#else
    // 32-bit code paths
#endif
```

### Binary Size Impact (Estimated)

| ABI | SIMD Enabled | Without SIMD | Delta |
|-----|--------------|--------------|-------|
| arm64-v8a | ~500 KB | ~350 KB | +43% |
| armeabi-v7a | ~450 KB | ~350 KB | +29% |
| x86_64 | ~600 KB | ~350 KB | +71% |
| x86 | ~700 KB | ~350 KB | +100% |

**Note:** SIMD code significantly increases size but provides 2-5x JPEG performance.

---

## 5. ARM-Specific Settings

### LOCAL_ARM_MODE := arm

Present in all modules:
- UVCCamera/Android.mk
- libjpeg-turbo/Android.mk
- libusb.mk
- libuvc/Android.mk

**Effect:** Forces 32-bit ARM instructions instead of Thumb-2.

| Mode | Code Density | Performance | Use Case |
|------|--------------|-------------|----------|
| arm | Lower | Slightly better | Performance-critical |
| thumb | Higher | Slightly lower | Code size optimization |

### NEON Status

| ABI | LOCAL_ARM_NEON | Actual Status |
|-----|----------------|---------------|
| armeabi-v7a | Commented out | Runtime detection |
| arm64-v8a | Not needed | Always available |

**Runtime Detection (jsimd_arm.c):**
```c
// SIMD dispatcher checks CPU features at runtime
if (simd_support & JSIMD_NEON)
    return jsimd_neon_function();
else
    return jsimd_c_function();
```

---

## 6. NDK Toolchain Handling

### MIPS Toolchain Workaround

```makefile
ifeq ($(NDK_TOOLCHAIN_VERSION),clang)
    # Disable MSA for Clang
    LOCAL_SRC_FILES += jsimd_none.c
else
    # Use MSA for GCC
    LOCAL_SRC_FILES += simd/jsimd_mips.c simd/jsimd_mips_dspr2.S
endif
```

**Context:** This code handles a known issue where Clang in NDK r13-r14 didn't properly support MIPS MSA (SIMD). The workaround uses GCC for MIPS builds.

**Current Status:** Irrelevant since:
1. MIPS removed from NDK r17+
2. GCC removed from NDK r18+
3. Project only builds armeabi-v7a and arm64-v8a

---

## 7. Platform-Specific Source Selection

### Summary by Module

| Module | Platform-Specific Code | Location |
|--------|----------------------|----------|
| libjpeg-turbo | SIMD assembly | simd/*.asm, simd/*.S |
| libusb | Android usbfs | os/android_usbfs.c |
| libuvc | None | Pure C |
| UVCCamera | None | C++ with Android JNI |

### Android-Specific Sources

**libusb:**
```makefile
LOCAL_SRC_FILES := \
    libusb/os/android_usbfs.c \    # Modified from linux_usbfs.c
    libusb/os/android_netlink.c \  # Modified from linux_netlink.c
```

**Note:** Standard Linux sources modified for Android-specific USB handling.

---

## 8. CMake Equivalent

### ABI-Conditional CMake

```cmake
# In CMakeLists.txt for libjpeg-turbo

if(ANDROID_ABI STREQUAL "arm64-v8a")
    target_sources(jpeg-turbo PRIVATE
        simd/jsimd_arm64.c
        simd/jsimd_arm64_neon.S
    )
    target_compile_definitions(jpeg-turbo PRIVATE SIZEOF_SIZE_T=8)

elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    target_sources(jpeg-turbo PRIVATE
        simd/jsimd_arm.c
        simd/jsimd_arm_neon.S
    )
    target_compile_definitions(jpeg-turbo PRIVATE SIZEOF_SIZE_T=4)

elseif(ANDROID_ABI STREQUAL "x86_64")
    target_sources(jpeg-turbo PRIVATE
        simd/jsimd_x86_64.c
        simd/jfdctflt-sse-64.asm
        # ... more .asm files
    )
    target_compile_definitions(jpeg-turbo PRIVATE
        SIZEOF_SIZE_T=8
        __x86_64__
    )
    enable_language(ASM_NASM)

elseif(ANDROID_ABI STREQUAL "x86")
    target_sources(jpeg-turbo PRIVATE
        simd/jsimd_i386.c
        simd/jsimdcpu.asm
        # ... more .asm files
    )
    target_compile_definitions(jpeg-turbo PRIVATE SIZEOF_SIZE_T=4)
    enable_language(ASM_NASM)

else()
    # Fallback: no SIMD
    target_sources(jpeg-turbo PRIVATE jsimd_none.c)
endif()
```

---

## 9. Recommendations

### Enable x86_64 for Emulator Testing

```makefile
# Current
APP_ABI := armeabi-v7a arm64-v8a

# Recommended for development
APP_ABI := armeabi-v7a arm64-v8a x86_64
```

**Benefits:**
- Fast Android Studio emulator testing
- No real-device deployment needed for basic testing
- Full SIMD support in emulator

### Enable NEON for armeabi-v7a

```makefile
# In libjpeg-turbo/Android.mk
ifeq ($(TARGET_ARCH_ABI),armeabi-v7a)
LOCAL_ARM_NEON := true  # Uncomment this line
```

**Trade-off:**
- Pro: 2-5x JPEG performance
- Con: Drops support for rare pre-2012 non-NEON devices

### Remove Deprecated ABI Code (Optional)

The following code blocks can be removed for cleaner maintenance:
- `ifeq ($(TARGET_ARCH_ABI),armeabi)` block
- `ifeq ($(TARGET_ARCH_ABI),mips)` block
- NDK_TOOLCHAIN_VERSION checks

---

## 10. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| PLAT-001 | Info | x86/x86_64 code present but not built | Enable for emulator |
| PLAT-002 | Low | armeabi-v7a NEON not explicitly enabled | Enable for performance |
| PLAT-003 | Info | Deprecated ABI code (armeabi, mips) | Remove for clarity |
| PLAT-004 | Info | MIPS GCC workaround obsolete | Remove |

### Positive Findings

| ID | Finding |
|----|---------|
| PLAT-P01 | Comprehensive SIMD coverage across ABIs |
| PLAT-P02 | Runtime NEON detection for armeabi-v7a |
| PLAT-P03 | Proper SIZEOF_SIZE_T handling |
| PLAT-P04 | Android-specific libusb adaptations |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **BUILD-002** | APP_ABI configuration |
| **BUILD-003** | ABI-specific compiler flags |
| **BUILD-007** | Detailed ABI analysis |
| **BUILD-010** | CMake ABI handling |

---

*End of BUILD-005*
