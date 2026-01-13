# SECURITY-009: Clang-Tidy Configuration

**Audit:** AUDIT-004 Android Security Compliance
**Generated:** 2026-01-11
**Target:** JNI Security Enforcement

---

## Overview

This directory contains Clang-Tidy configuration for enforcing Android 16 security requirements at build time.

## Contents

| File | Purpose |
|------|---------|
| `.clang-tidy` | Main configuration with custom JNI security checks |
| `CMakeLists.txt.example` | CMake integration example |
| `ci-workflow.yml` | GitHub Actions CI/CD pipeline |

## Custom Checks

### 1. `jni-no-raw-pointer-cast`

**Detects:** `reinterpret_cast<SomeType*>(jlong)` in JNI functions

**Why:** Causes MTE violations on ARMv9, 32-bit truncation on ILP32, pointer provenance loss.

**Fix:** Use HandleManager pattern - `handleManager.acquire(handle)`

### 2. `jni-no-direct-device-access`

**Detects:** `libusb_open()`, `libusb_get_device_list()`, `uvc_open()`

**Why:** Violates Android 16 Privacy Sandbox - triggers "Hidden Hardware Access" flags.

**Fix:** Use FD injection - receive FD from `UsbDeviceConnection.getFileDescriptor()`, call `libusb_wrap_sys_device()`

### 3. `jni-no-raw-storage-path`

**Detects:** `fopen("/sdcard/...")` or similar raw paths

**Why:** Blocked by Scoped Storage on Android 11+.

**Fix:** Receive FD from SAF/MediaStore via JNI, use `write(fd, ...)`

## Requirements

- **Clang-Tidy 20+** (NDK r28+ or LLVM 20)
- **CustomChecks support** (Query-Based checks)

## Installation

### Option 1: Copy to Project Root

```bash
cp .clang-tidy /path/to/project/
```

### Option 2: Use from This Directory

```bash
clang-tidy -config-file=/path/to/SECURITY-009-clang-tidy-config/.clang-tidy src/*.cpp
```

## Usage

### Manual Run

```bash
clang-tidy -p build/ -config-file=.clang-tidy src/main/jni/UVCCamera/*.cpp
```

### CMake Integration

See `CMakeLists.txt.example` for full integration.

```cmake
set(CMAKE_CXX_CLANG_TIDY
    "clang-tidy"
    "-config-file=${CMAKE_SOURCE_DIR}/.clang-tidy"
    "-warnings-as-errors=jni-no-raw-pointer-cast"
)
```

### CI/CD Integration

Copy `ci-workflow.yml` to `.github/workflows/` for automated enforcement.

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-003** | JNI safety patterns |
| **SECURITY-001** | USB access patterns |
| **SECURITY-004** | Scoped Storage compliance |
| **AUDIT-004** | Full security audit specification |

---

*End of SECURITY-009 README*
