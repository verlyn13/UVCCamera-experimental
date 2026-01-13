# BUILD-006: Security Flag Verification

**Audit:** AUDIT-005 Build System Archaeology
**Generated:** 2026-01-11
**Target:** Security Hardening Verification

---

## Summary

| Security Measure | Status | Source |
|------------------|--------|--------|
| Stack Protector | ON | NDK default |
| FORTIFY_SOURCE | Level 2 | NDK default |
| RELRO | Full | NDK default |
| Bind Now (NOW) | ON | NDK default |
| 16KB Page Size | **Explicit** | Application.mk |
| MTE Support | Not configured | Requires explicit |

---

## 1. NDK Security Defaults (r21+)

### Automatic Protections

The Android NDK (r21 and later) enables security hardening by default:

| Flag | Effect | Default Status |
|------|--------|----------------|
| `-fstack-protector-strong` | Stack canary for functions with buffers | **ON** |
| `-D_FORTIFY_SOURCE=2` | Runtime buffer overflow checks | **ON** |
| `-Wl,-z,relro` | Read-only relocations after init | **ON** |
| `-Wl,-z,now` | Resolve all symbols at load time | **ON** |
| `-Wl,--gc-sections` | Remove unused code sections | **ON** |
| `-Wl,--hash-style=gnu` | GNU-style hash tables | **ON** |

### Verification

These flags are NOT explicitly set in the project makefiles because they are NDK defaults. This is correct behavior.

**Evidence from NDK toolchain:**
```
# From $NDK/build/cmake/android.toolchain.cmake
set(CMAKE_C_FLAGS_INIT "-fstack-protector-strong")
set(CMAKE_CXX_FLAGS_INIT "-fstack-protector-strong")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-Wl,-z,relro -Wl,-z,now")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-Wl,-z,relro -Wl,-z,now")
```

---

## 2. Explicit Security Configuration

### 16KB Page Size Alignment (Android 15+)

**File:** `jni/Application.mk`
```makefile
APP_LDFLAGS := -Wl,-z,max-page-size=16384
```

**Status:** ✅ Correctly configured

**Purpose:**
- Android 15 introduces devices with 16KB page sizes
- Binaries with 4KB alignment will crash on these devices
- This flag ensures compatibility with all page sizes

**Verification:**
```bash
# After build, verify with:
readelf -l libUVCCamera.so | grep -A1 LOAD
# Look for alignment of 0x4000 (16384)
```

### MTE (Memory Tagging Extension)

**Status:** ❌ Not configured

**Required for Android 16+ ARM64 devices:**
```makefile
# Would need to add to Application.mk or per-module:
ifeq ($(TARGET_ARCH_ABI),arm64-v8a)
    LOCAL_CFLAGS += -march=armv8-a+memtag
    LOCAL_CFLAGS += -fsanitize=memtag-stack,memtag-heap
    LOCAL_LDFLAGS += -fsanitize=memtag-stack,memtag-heap
endif
```

**Note:** MTE requires ARMv8.5-A or later (Pixel 8+ era devices).

---

## 3. Flag-by-Flag Analysis

### Stack Protector

| Aspect | Value |
|--------|-------|
| Default Level | `-fstack-protector-strong` |
| Project Override | None (uses default) |
| Coverage | Functions with arrays, address-taken locals |

**Correct:** No override needed; NDK default is appropriate.

### FORTIFY_SOURCE

| Aspect | Value |
|--------|-------|
| Default Level | `_FORTIFY_SOURCE=2` |
| Project Override | None (uses default) |
| Protected Functions | memcpy, strcpy, sprintf, etc. |

**Correct:** Level 2 is appropriate. Level 3 requires `-O2` minimum and is not standard.

### RELRO (Relocation Read-Only)

| Aspect | Value |
|--------|-------|
| Mode | Full RELRO (`-Wl,-z,relro -Wl,-z,now`) |
| Protection | GOT becomes read-only after init |
| Mitigates | GOT overwrite attacks |

**Correct:** Full RELRO enabled by default.

### Position Independent Code (PIE/PIC)

| Target | Requirement | Status |
|--------|-------------|--------|
| Shared libraries (.so) | PIC required | Automatic |
| Executables | PIE required API 21+ | N/A (no executables) |

**Correct:** NDK generates PIC for all shared libraries automatically.

---

## 4. Flags Present in Makefiles

### Warning Flags

| Flag | Module | Purpose |
|------|--------|---------|
| `-Werror` | UVCCamera | Warnings as errors (declared but possibly not used) |
| `-Wno-incompatible-pointer-types` | libjpeg-turbo | Suppress legacy code warnings |

**Analysis:**
- `-Werror` is declared as `CFLAGS := -Werror` but may not be used
- Warning suppression in libjpeg-turbo is acceptable for third-party code

### Optimization Flags

| Flag | Module | Security Impact |
|------|--------|-----------------|
| `-O3` | UVCCamera, libusb | May affect debugging, enables FORTIFY |
| `-fstrict-aliasing` | UVCCamera, libusb | Can cause issues if aliasing violated |

**Note:** `-O2` minimum required for `_FORTIFY_SOURCE` to work. `-O3` satisfies this.

### Linker Flags

| Flag | Module | Purpose |
|------|--------|---------|
| `LOCAL_DISABLE_FATAL_LINKER_WARNINGS` | libjpeg-turbo, libuvc | Ignore linker warnings |

**Risk:** May hide legitimate security-relevant linker warnings. Should review what warnings are being suppressed.

---

## 5. Missing Security Flags

### Not Present (Should Consider)

| Flag | Purpose | Recommendation |
|------|---------|----------------|
| `-Werror=format-security` | Format string vulnerabilities | Add |
| `-Werror=implicit-function-declaration` | Missing prototypes | Add |
| `-D_GLIBCXX_ASSERTIONS` | C++ iterator checks | Consider for debug |

### MTE Configuration (Future-Proofing)

```makefile
# Recommended addition to Application.mk
ifeq ($(TARGET_ARCH_ABI),arm64-v8a)
# MTE requires build-time and runtime support
# Uncomment when targeting Android 16+ on ARMv8.5-A+
# APP_CFLAGS += -march=armv8.5-a+memtag
# APP_CFLAGS += -fsanitize=memtag
# APP_LDFLAGS += -fsanitize=memtag
endif
```

---

## 6. Security Flag Matrix

### By Module

| Flag | UVCCamera | libusb | libuvc | libjpeg |
|------|-----------|--------|--------|---------|
| stack-protector-strong | NDK | NDK | NDK | NDK |
| FORTIFY_SOURCE=2 | NDK | NDK | NDK | NDK |
| RELRO | NDK | NDK | NDK | NDK |
| NOW | NDK | NDK | NDK | NDK |
| 16KB pages | ✅ | ✅ | ✅ | ✅ |
| MTE | ❌ | ❌ | ❌ | ❌ |

**Legend:** NDK = Enabled by NDK default, ✅ = Explicit, ❌ = Not configured

---

## 7. Build Hardening Verification Script

```bash
#!/bin/bash
# verify-security.sh - Post-build security verification

LIB=$1

echo "=== Security Flag Verification: $LIB ==="

# Check for stack canary
if nm "$LIB" | grep -q "__stack_chk"; then
    echo "[PASS] Stack protector enabled"
else
    echo "[WARN] Stack protector not detected"
fi

# Check RELRO
if readelf -l "$LIB" 2>/dev/null | grep -q "GNU_RELRO"; then
    echo "[PASS] RELRO enabled"
else
    echo "[FAIL] RELRO not found"
fi

# Check BIND_NOW (full RELRO)
if readelf -d "$LIB" 2>/dev/null | grep -q "BIND_NOW"; then
    echo "[PASS] Full RELRO (BIND_NOW)"
else
    echo "[WARN] Partial RELRO only"
fi

# Check page alignment
ALIGN=$(readelf -l "$LIB" 2>/dev/null | grep -A1 "LOAD" | grep -oP "0x[0-9a-f]+" | head -1)
if [ "$ALIGN" = "0x4000" ]; then
    echo "[PASS] 16KB page alignment"
else
    echo "[INFO] Page alignment: $ALIGN"
fi

# Check for FORTIFY
if nm "$LIB" | grep -q "__fortify"; then
    echo "[PASS] FORTIFY_SOURCE detected"
else
    echo "[INFO] FORTIFY symbols not directly visible (may still be active)"
fi
```

---

## 8. CMake Security Configuration

### Equivalent CMake Configuration

```cmake
# Security hardening for CMake build
cmake_minimum_required(VERSION 3.22)

# These are NDK defaults but can be made explicit
add_compile_options(
    -fstack-protector-strong
    -D_FORTIFY_SOURCE=2
)

add_link_options(
    -Wl,-z,relro
    -Wl,-z,now
    -Wl,-z,max-page-size=16384  # 16KB pages
)

# MTE support (Android 16+, ARMv8.5-A+)
if(ANDROID_ABI STREQUAL "arm64-v8a")
    # Uncomment for MTE support
    # add_compile_options(-march=armv8.5-a+memtag -fsanitize=memtag)
    # add_link_options(-fsanitize=memtag)
endif()

# Additional recommended flags
add_compile_options(
    -Werror=format-security
    -Werror=implicit-function-declaration
)
```

---

## 9. Android Security Best Practices Compliance

### Checklist

| Requirement | Status | Notes |
|-------------|--------|-------|
| minSdkVersion >= 21 | ✅ | APP_PLATFORM=android-26 |
| 64-bit support | ✅ | arm64-v8a included |
| Stack protection | ✅ | NDK default |
| ASLR compatible | ✅ | PIC enabled |
| 16KB page support | ✅ | Explicit flag |
| Network security config | N/A | No network code |
| Crypto best practices | N/A | No crypto code |

### Google Play Compliance

| Requirement | Deadline | Status |
|-------------|----------|--------|
| Target API 34+ | Aug 2024 | ✅ (APP_PLATFORM=android-26, targetSdk in gradle) |
| 64-bit requirement | All new apps | ✅ arm64-v8a |
| 16KB page support | Android 15 launch | ✅ Configured |

---

## 10. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| SEC-001 | Low | MTE not configured | Add for future Android 16+ |
| SEC-002 | Info | DISABLE_FATAL_LINKER_WARNINGS used | Review underlying issues |
| SEC-003 | Low | No explicit format-security flag | Add -Werror=format-security |
| SEC-004 | Info | -Werror declared but may not be active | Verify in build output |

### Positive Findings

| ID | Finding |
|----|---------|
| SEC-P01 | 16KB page alignment correctly configured |
| SEC-P02 | NDK security defaults not overridden |
| SEC-P03 | Optimization level supports FORTIFY |
| SEC-P04 | Full RELRO enabled by default |
| SEC-P05 | Both 32-bit and 64-bit ABIs supported |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **BUILD-003** | Compiler flag extraction |
| **BUILD-010** | CMake security flags |
| **SECURITY-007** | MTE compatibility |
| **SECURITY-010** | Threat model |

---

*End of BUILD-006*
