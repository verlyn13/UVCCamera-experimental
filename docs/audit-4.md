# AUDIT-004: Android Security Compliance

**Status:** Draft
**Created:** 2026-01-11
**Author:** Jeffrey Litecky / Claude
**Project:** ScopeCam - UVCCamera Library Modernization
**Target:** Android 16 (API 36) / NDK r28+ / GKI 6.1+
**Prerequisites:** AUDIT-001, AUDIT-002, AUDIT-003 Complete

---

## Executive Summary

This audit evaluates the UVCCamera codebase against Android 16's **Zero-Trust Hardware** security model. The platform has fundamentally shifted from permission-as-capability to session-based, hardware-enforced access control. Legacy patterns that worked on Android 10-14 are now **security triggers** that cause immediate process termination, permission revocation, or app store rejection.

**Core Philosophy:** The native library must be **passive**. It receives resources (file descriptors, buffers) from the managed layer—it never discovers, opens, or owns hardware directly.

**Critical Findings Preview:**
1. Direct `/dev/bus/usb` scanning triggers **Privacy Sandbox "Hidden Hardware Access"** flags
2. `jlong` pointer casting violates **MTE (Memory Tagging Extension)** on Tensor G5/G6
3. Raw file path access (`fopen("/sdcard/...")`) blocked by **Scoped Storage**
4. USB connections require **`connectedDevice` Foreground Service** for session persistence

**Audit Scope:** Android manifest, JNI boundary patterns, USB access architecture, storage access patterns
**Expected Duration:** 6-8 hours for complete compliance assessment
**Output Artifacts:** 10 structured deliverables

---

## Table of Contents

1. [Objectives](#1-objectives)
2. [Pre-Audit Requirements](#2-pre-audit-requirements)
3. [Android 16 Security Model Overview](#3-android-16-security-model-overview)
4. [Audit Tasks](#4-audit-tasks)
   - 4.1 [USB Permission Architecture Audit](#41-usb-permission-architecture-audit)
   - 4.2 [File Descriptor Injection Analysis](#42-file-descriptor-injection-analysis)
   - 4.3 [JNI Memory Safety Assessment](#43-jni-memory-safety-assessment)
   - 4.4 [Scoped Storage Compliance](#44-scoped-storage-compliance)
   - 4.5 [Manifest Permission Audit](#45-manifest-permission-audit)
   - 4.6 [Privacy Sandbox Compliance](#46-privacy-sandbox-compliance)
   - 4.7 [Memory Tagging Extension (MTE) Compatibility](#47-memory-tagging-extension-mte-compatibility)
   - 4.8 [Foreground Service Requirements](#48-foreground-service-requirements)
   - 4.9 [Clang-Tidy Enforcement Configuration](#49-clang-tidy-enforcement-configuration)
   - 4.10 [Security Threat Model](#410-security-threat-model)
5. [Migration Architecture](#5-migration-architecture)
6. [Deliverables](#6-deliverables)
7. [Verification Criteria](#7-verification-criteria)
8. [Agent Instructions](#8-agent-instructions)

---

## 1. Objectives

### Primary Objectives

| ID | Objective | Success Criteria |
|----|-----------|------------------|
| O1 | Audit USB permission architecture | All direct device access patterns identified |
| O2 | Assess FD injection readiness | Migration path to passive native architecture documented |
| O3 | Evaluate JNI memory safety | All `jlong` pointer casts catalogued |
| O4 | Verify Scoped Storage compliance | All raw file path access identified |
| O5 | Audit manifest permissions | All permissions mapped to Android 16 requirements |

### Secondary Objectives

| ID | Objective | Success Criteria |
|----|-----------|------------------|
| O6 | Privacy Sandbox compliance | Hidden Hardware Access patterns flagged |
| O7 | MTE compatibility assessment | Pointer provenance violations identified |
| O8 | Foreground Service configuration | `connectedDevice` FGS requirements documented |
| O9 | Clang-Tidy enforcement | Custom check configuration produced |
| O10 | Security threat model | Attack surface documented |

### Android 16 Compliance Targets

| Legacy Pattern | Android 16 Requirement | Violation Consequence |
|----------------|------------------------|----------------------|
| Direct USB device scanning | FD injection from managed layer | Privacy Sandbox flag |
| `jlong` pointer casting | Handle/Map registry | MTE termination |
| Raw `/sdcard/` access | SAF + FD injection | Storage permission denial |
| Background USB access | `connectedDevice` FGS | Connection dropped |
| USB open without permission | `UsbManager.requestPermission()` | SecurityException |

---

## 2. Pre-Audit Requirements

### 2.1 Prerequisite Artifacts

| Artifact | Source | Required For |
|----------|--------|--------------|
| INVENTORY-001 | AUDIT-001 | Source file list for scanning |
| INVENTORY-002 | AUDIT-001 | JNI file identification |
| SAFETY-006 | AUDIT-002 | JNI boundary inventory |
| CONCURRENCY-008 | AUDIT-003 | JNI thread attachment patterns |

### 2.2 Required Tools

| Tool | Purpose | Installation |
|------|---------|--------------|
| `grep`/`ripgrep` | Pattern searching | System |
| `clang-tidy` (v20+) | Static analysis with custom checks | NDK r28+ |
| `aapt2` | Manifest analysis | Android SDK |
| `apkanalyzer` | Permission extraction | Android SDK |
| `jadx` | DEX decompilation (if needed) | `apt install jadx` |

### 2.3 Reference Documentation

| Document | URL | Purpose |
|----------|-----|---------|
| Android 16 Behavior Changes | developer.android.com | API 36 requirements |
| USB Host Guide | developer.android.com | UsbManager patterns |
| Scoped Storage Guide | developer.android.com | SAF migration |
| MTE Developer Guide | source.android.com | Memory tagging requirements |

### 2.4 Scan Configuration

```bash
# Define paths
JNI_PATH="/path/to/jni"
MANIFEST_PATH="/path/to/AndroidManifest.xml"
KOTLIN_PATH="/path/to/src/main/kotlin"
JAVA_PATH="/path/to/src/main/java"
```

---

## 3. Android 16 Security Model Overview

### 3.1 The Zero-Trust Hardware Posture

Android 16 implements a **defense-in-depth** model for hardware access:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     ANDROID 16 USB SECURITY LAYERS                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Layer 1: Hardware (USB Controller)                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  Advanced Data Protection: Data pins physically disabled when locked   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              ▼                                               │
│  Layer 2: Kernel (uvcvideo / libusb)                                        │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  SELinux: Native code cannot access /dev/bus/usb directly              │ │
│  │  seccomp: Restricted syscall set for app processes                     │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              ▼                                               │
│  Layer 3: Framework (UsbManager)                                            │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  Permission gating: requestPermission() required before openDevice()   │ │
│  │  Session tracking: FD validity tied to permission grant                │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              ▼                                               │
│  Layer 4: App Process                                                       │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  MTE: Memory tagging catches stale/corrupted pointers                  │ │
│  │  Privacy Sandbox: Hardware discovery patterns flagged                  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 The Passive Native Architecture

**Legacy (Prohibited):**
```cpp
// Native code "discovers" and "opens" device
libusb_device** list;
libusb_get_device_list(ctx, &list);  // ❌ HIDDEN HARDWARE ACCESS
libusb_open(list[0], &handle);       // ❌ DIRECT DEVICE OPEN
```

**Android 16 (Required):**
```cpp
// Native code receives FD from managed layer
void nativeInit(JNIEnv* env, jobject, jint fd) {
    // fd comes from UsbDeviceConnection.getFileDescriptor()
    libusb_device_handle* handle;
    libusb_wrap_sys_device(ctx, fd, &handle);  // ✓ FD INJECTION
}
```

### 3.3 Permission Lifecycle Changes

| Event | Android 14 | Android 16 |
|-------|------------|------------|
| App requests USB permission | Dialog shown | Dialog shown |
| User grants permission | Persistent until revoke | **Session-scoped** |
| Screen locks (ADP enabled) | Connection persists | **Data pins disabled** (unless FGS) |
| Cable disconnected while locked | Re-enumeration on unlock | **Blocked until unlock + re-plug** |
| App backgrounded (no FGS) | Connection may persist | **Connection dropped** |

### 3.4 MTE and Pointer Provenance

On Tensor G5/G6 and other ARMv9 devices, **Memory Tagging Extension (MTE)** is enabled for system apps and increasingly for third-party apps.

**The `jlong` Pointer Cast Hazard:**
```cpp
// This pattern triggers MTE violations
JNIEXPORT void JNICALL Java_MyClass_process(JNIEnv*, jobject, jlong handle) {
    auto* obj = reinterpret_cast<MyObject*>(handle);  // ❌ MTE VIOLATION
    // The pointer "emerges" from an integer with no provenance
    // MTE cannot verify the tag → SIGSEGV or silent corruption
}
```

**MTE Behavior:**
- Each pointer carries a 4-bit tag in the top byte (TBI - Top Byte Ignore)
- Memory allocations are tagged
- Pointer access verifies tag matches allocation tag
- Integer-to-pointer casts produce pointers with **no tag** → immediate fault or bypass

---

## 4. Audit Tasks

### 4.1 USB Permission Architecture Audit

**Objective:** Identify all patterns where native code directly accesses USB devices

#### 4.1.1 Direct Device Access Detection

```bash
# libusb device enumeration (PROHIBITED)
grep -rn 'libusb_get_device_list\|libusb_open\|libusb_open_device_with_vid_pid' $JNI_PATH --include="*.c" --include="*.cpp" > audit/libusb-direct-access.txt

# Raw /dev access (PROHIBITED)
grep -rn '/dev/bus/usb\|/dev/video\|/dev/v4l' $JNI_PATH --include="*.c" --include="*.cpp" > audit/dev-raw-access.txt

# open() syscall on device paths
grep -rn 'open\s*(\s*"/' $JNI_PATH --include="*.c" --include="*.cpp" > audit/open-syscall.txt

# libuvc device discovery
grep -rn 'uvc_find_device\|uvc_get_device_list\|uvc_open' $JNI_PATH --include="*.c" --include="*.cpp" > audit/libuvc-discovery.txt
```

#### 4.1.2 Permission Request Pattern Analysis

```bash
# Check for UsbManager usage in Kotlin/Java
grep -rn 'UsbManager\|requestPermission\|openDevice\|getFileDescriptor' $KOTLIN_PATH $JAVA_PATH --include="*.kt" --include="*.java" > audit/usb-permission-flow.txt

# Check for permission broadcast receivers
grep -rn 'USB_PERMISSION\|ACTION_USB_DEVICE' $KOTLIN_PATH $JAVA_PATH --include="*.kt" --include="*.java" >> audit/usb-permission-flow.txt
```

#### 4.1.3 USB Access Pattern Catalog Template

```markdown
### USB Access Pattern: [IDENTIFIER]

**Location:** `libuvc/src/device.c:342`
**Pattern:** `libusb_open(dev, &handle)`
**Classification:** DIRECT_DEVICE_OPEN

**Context:**
```c
int uvc_open(uvc_device_t* dev, uvc_device_handle_t** handle) {
    libusb_device_handle* usb_handle;
    int ret = libusb_open(dev->usb_dev, &usb_handle);  // PROHIBITED
    // ...
}
```

**Android 16 Violation:**
- **SELinux:** App process lacks `usb_device` access
- **Privacy Sandbox:** Triggers "Hidden Hardware Access" flag
- **Manifest:** Requires `android.hardware.usb.host` feature

**Migration Requirement:**
Replace with FD injection:
```cpp
int uvc_open_from_fd(int fd, uvc_device_handle_t** handle) {
    libusb_device_handle* usb_handle;
    int ret = libusb_wrap_sys_device(ctx, fd, &usb_handle);  // ✓ COMPLIANT
    // ...
}
```

**Risk Level:** CRITICAL (App will not function on Android 16)
**Migration Effort:** HIGH (Requires architectural refactor)
```

#### 4.1.4 Deliverable: SECURITY-001-usb-access.md

Complete USB access pattern inventory with migration requirements.

---

### 4.2 File Descriptor Injection Analysis

**Objective:** Assess readiness for passive FD injection architecture

#### 4.2.1 Current FD Handling Detection

```bash
# Find where FDs enter native code
grep -rn 'jint\s\+fd\|jint\s\+fileDescriptor\|GetIntField.*fd' $JNI_PATH --include="*.cpp" > audit/fd-entry-points.txt

# Find libusb FD usage
grep -rn 'libusb_wrap_sys_device\|libusb_set_option.*WEAK_AUTHORITY' $JNI_PATH --include="*.c" --include="*.cpp" > audit/libusb-fd-injection.txt

# Find native device open patterns that should use FD
grep -rn 'uvc_open\|uvc_init\|libusb_init' $JNI_PATH --include="*.c" --include="*.cpp" > audit/device-init.txt
```

#### 4.2.2 libusb Version and Capability Check

```bash
# Check libusb version (must support wrap_sys_device)
grep -rn 'LIBUSB_API_VERSION\|libusb_wrap_sys_device' $JNI_PATH --include="*.c" --include="*.cpp" --include="*.h" > audit/libusb-version.txt

# Check for libusb context initialization
grep -rn 'libusb_init\|libusb_init_context' $JNI_PATH --include="*.c" --include="*.cpp" > audit/libusb-init.txt
```

#### 4.2.3 FD Injection Readiness Assessment

| Requirement | Current Status | Migration Needed |
|-------------|---------------|------------------|
| libusb 1.0.23+ (wrap_sys_device) | ? | Version check |
| JNI accepts `jint fd` parameter | ? | Signature change |
| No `libusb_open()` calls | ? | Replace all |
| No `libusb_get_device_list()` | ? | Remove discovery |
| RAII FD wrapper (UniqueFd) | ? | Add from Phase 2 |

#### 4.2.4 FD Injection Architecture Template

```cpp
// Target architecture for Android 16 compliance

// Kotlin/Java side
class UsbCameraManager(private val context: Context) {
    private val usbManager = context.getSystemService(UsbManager::class.java)

    suspend fun openCamera(device: UsbDevice): CameraHandle {
        // 1. Request permission (shows dialog)
        val granted = requestPermission(device)
        if (!granted) throw SecurityException("USB permission denied")

        // 2. Open connection (framework-managed)
        val connection = usbManager.openDevice(device)
            ?: throw IOException("Failed to open device")

        // 3. Extract FD (this is what native code receives)
        val fd = connection.fileDescriptor

        // 4. Pass FD to native (NOT the pointer!)
        val handle = nativeInit(fd)

        return CameraHandle(handle, connection)
    }

    private external fun nativeInit(fd: Int): Long  // Returns handle ID
}

// Native side (C++23)
JNIEXPORT jlong JNICALL Java_..._nativeInit(JNIEnv* env, jobject, jint fd) {
    // Wrap FD in RAII
    auto unique_fd = UniqueFd(fd);  // Does NOT own - Java owns the connection

    // Initialize libusb with injected FD
    libusb_context* ctx;
    libusb_init_context(&ctx, nullptr, 0);

    libusb_device_handle* usb_handle;
    int ret = libusb_wrap_sys_device(ctx, fd, &usb_handle);
    if (ret < 0) {
        ThrowJniException(env, "java/io/IOException", "Failed to wrap USB FD");
        return 0;
    }

    // Create camera object
    auto camera = std::make_unique<UVCCamera>(usb_handle);

    // Register in HandleMap (NOT pointer cast!)
    return CameraRegistry::Register(std::move(camera));
}
```

#### 4.2.5 Deliverable: SECURITY-002-fd-injection.md

FD injection readiness assessment with architectural migration plan.

---

### 4.3 JNI Memory Safety Assessment

**Objective:** Catalog all `jlong` pointer casts for Handle/Map migration

#### 4.3.1 Pointer Cast Detection

```bash
# C-style casts from jlong
grep -rn '(.*\*)\s*[a-zA-Z_]*[Hh]andle\|(.*\*)\s*[a-zA-Z_]*[Pp]tr' $JNI_PATH --include="*.cpp" > audit/jlong-cstyle-cast.txt

# reinterpret_cast from jlong
grep -rn 'reinterpret_cast.*jlong\|reinterpret_cast.*handle\|reinterpret_cast.*ptr' $JNI_PATH --include="*.cpp" > audit/jlong-reinterpret-cast.txt

# Casting TO jlong (allocation return)
grep -rn '(jlong)\s*new\s\|(jlong)\s*[a-zA-Z_]*\*\|reinterpret_cast<jlong>' $JNI_PATH --include="*.cpp" > audit/jlong-alloc-cast.txt

# intptr_t intermediate casts (evasion pattern)
grep -rn 'intptr_t\|uintptr_t' $JNI_PATH --include="*.cpp" > audit/intptr-casts.txt
```

#### 4.3.2 JNI Function Signature Analysis

```bash
# Find all JNI functions that accept jlong (potential pointer handles)
grep -rn 'JNIEXPORT.*jlong\|jlong\s\+[a-zA-Z_]*[Hh]andle\|jlong\s\+[a-zA-Z_]*[Pp]tr\|jlong\s\+native' $JNI_PATH --include="*.cpp" > audit/jni-jlong-params.txt

# Find JNI functions that return jlong (potential pointer leaks)
grep -rn 'JNIEXPORT\s\+jlong' $JNI_PATH --include="*.cpp" > audit/jni-jlong-return.txt
```

#### 4.3.3 Pointer Cast Hazard Catalog

| Hazard Type | Detection Pattern | Risk Level | MTE Impact |
|-------------|-------------------|------------|------------|
| Direct Cast | `(MyObj*)handle` | CRITICAL | Immediate SIGSEGV |
| reinterpret_cast | `reinterpret_cast<MyObj*>(handle)` | CRITICAL | Immediate SIGSEGV |
| intptr_t Evasion | `(void*)(intptr_t)handle` | CRITICAL | 32-bit truncation + MTE |
| Allocation Leak | `return (jlong)new MyObj()` | HIGH | Provenance loss |

#### 4.3.4 JNI Pointer Cast Catalog Template

```markdown
### JNI Pointer Cast: [FUNCTION_NAME]

**Location:** `UVCCamera/UVCCamera.cpp:156`
**JNI Signature:** `Java_com_example_UVCCamera_nativeSetParam`

**Violation:**
```cpp
JNIEXPORT void JNICALL Java_..._nativeSetParam(
    JNIEnv* env, jobject thiz, jlong handle, jint param, jint value)
{
    auto* camera = reinterpret_cast<UVCCamera*>(handle);  // ❌ PROHIBITED
    camera->setParam(param, value);
}
```

**Hazards:**
1. **MTE Violation:** Pointer has no allocation tag → SIGSEGV on ARMv9
2. **32-bit Truncation:** If `handle` exceeds 32 bits on ILP32
3. **Provenance Loss:** Optimizer cannot track pointer origin
4. **Use-After-Free:** No validation that `handle` is still valid

**Compliant Refactor:**
```cpp
JNIEXPORT void JNICALL Java_..._nativeSetParam(
    JNIEnv* env, jobject thiz, jlong handle, jint param, jint value)
{
    auto result = CameraRegistry::Get(handle);  // ✓ Handle lookup
    if (!result) {
        ThrowJniException(env, "java/lang/IllegalStateException",
                          "Invalid camera handle");
        return;
    }
    (*result)->setParam(param, value);
}
```

**Risk Level:** CRITICAL
**Migration Effort:** MEDIUM (Registry pattern)
```

#### 4.3.5 Deliverable: SECURITY-003-jni-safety.md

Complete JNI pointer cast catalog with Handle/Map migration plan.

---

### 4.4 Scoped Storage Compliance

**Objective:** Identify all raw file path access for SAF migration

#### 4.4.1 Raw Path Detection

```bash
# Direct /sdcard/ access
grep -rn '/sdcard\|/storage/emulated\|/mnt/sdcard\|Environment.getExternalStorageDirectory' $JNI_PATH $KOTLIN_PATH $JAVA_PATH --include="*.c" --include="*.cpp" --include="*.kt" --include="*.java" > audit/raw-storage-paths.txt

# fopen with path strings
grep -rn 'fopen\s*(\s*"\|fopen\s*(\s*path\|fopen\s*(\s*file' $JNI_PATH --include="*.c" --include="*.cpp" > audit/fopen-paths.txt

# Native file operations
grep -rn 'open\s*(\s*"\|creat\s*(\|mkdir\s*(' $JNI_PATH --include="*.c" --include="*.cpp" > audit/native-file-ops.txt

# FILE* usage
grep -rn 'FILE\s*\*\|fprintf\|fwrite\|fread' $JNI_PATH --include="*.c" --include="*.cpp" > audit/file-pointer-usage.txt
```

#### 4.4.2 Storage Access Pattern Classification

| Pattern | Android 16 Status | Migration Path |
|---------|-------------------|----------------|
| `/sdcard/DCIM/...` | BLOCKED | MediaStore API |
| `/sdcard/Download/...` | BLOCKED | SAF DocumentFile |
| App-specific files | ALLOWED | `getExternalFilesDir()` |
| Cache files | ALLOWED | `getCacheDir()` |
| FD from SAF | ALLOWED | `contentResolver.openFd()` |

#### 4.4.3 Scoped Storage Migration Template

```markdown
### Storage Access: [IDENTIFIER]

**Location:** `UVCCamera/capture.cpp:234`
**Pattern:** Direct `/sdcard/` write

**Violation:**
```cpp
void saveFrame(const uint8_t* data, size_t size, const char* filename) {
    char path[256];
    snprintf(path, sizeof(path), "/sdcard/DCIM/ScopeCam/%s", filename);
    FILE* f = fopen(path, "wb");  // ❌ BLOCKED ON ANDROID 16
    fwrite(data, 1, size, f);
    fclose(f);
}
```

**Android 16 Behavior:**
- `fopen` returns `NULL`, `errno = EACCES`
- Even with `WRITE_EXTERNAL_STORAGE` permission
- Scoped Storage enforced regardless of `requestLegacyExternalStorage`

**Compliant Refactor:**
```cpp
// Native side - receives FD from Kotlin
void saveFrameToFd(const uint8_t* data, size_t size, int fd) {
    write(fd, data, size);  // ✓ FD INJECTION
}

// Kotlin side - handles SAF
suspend fun saveFrame(data: ByteArray, filename: String) {
    val uri = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    val values = ContentValues().apply {
        put(MediaStore.Images.Media.DISPLAY_NAME, filename)
        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
        put(MediaStore.Images.Media.RELATIVE_PATH, "DCIM/ScopeCam")
    }
    val imageUri = contentResolver.insert(uri, values)
    contentResolver.openFileDescriptor(imageUri!!, "w")?.use { pfd ->
        nativeSaveFrame(data, pfd.fd)  // Pass FD to native
    }
}
```

**Risk Level:** HIGH (Feature will not function)
**Migration Effort:** MEDIUM
```

#### 4.4.4 Deliverable: SECURITY-004-scoped-storage.md

Scoped Storage compliance assessment with migration patterns.

---

### 4.5 Manifest Permission Audit

**Objective:** Verify all required permissions and features are declared

#### 4.5.1 Manifest Extraction

```bash
# Extract permissions from manifest
grep -E '<uses-permission|<uses-feature|android:foregroundServiceType' $MANIFEST_PATH > audit/manifest-permissions.txt

# Check for USB-specific declarations
grep -E 'USB|usb|FOREGROUND_SERVICE' $MANIFEST_PATH > audit/manifest-usb.txt

# Check for storage permissions
grep -E 'STORAGE|storage|MEDIA|media' $MANIFEST_PATH > audit/manifest-storage.txt
```

#### 4.5.2 Required Permissions Matrix

| Permission/Feature | Required For | Status |
|-------------------|--------------|--------|
| `android.hardware.usb.host` | USB host mode | ? |
| `android.permission.USB_PERMISSION` | UsbManager access | ? |
| `android.permission.FOREGROUND_SERVICE` | Background USB | ? |
| `android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE` | USB FGS type | **MANDATORY** |
| `android.permission.POST_NOTIFICATIONS` | FGS notification (API 33+) | ? |
| `android.permission.READ_MEDIA_IMAGES` | MediaStore read | ? |
| `android.permission.READ_MEDIA_VIDEO` | MediaStore read | ? |

#### 4.5.3 Service Declaration Requirements

```xml
<!-- Required for Android 14+ USB access -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>

<application>
    <service
        android:name=".UsbCameraService"
        android:foregroundServiceType="connectedDevice"
        android:exported="false">
        <intent-filter>
            <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"/>
        </intent-filter>
        <meta-data
            android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
            android:resource="@xml/device_filter"/>
    </service>
</application>
```

#### 4.5.4 Deliverable: SECURITY-005-manifest.md

Complete manifest permission audit with required additions.

---

### 4.6 Privacy Sandbox Compliance

**Objective:** Identify patterns that trigger Privacy Sandbox flags

#### 4.6.1 Hidden Hardware Access Detection

```bash
# Device enumeration patterns
grep -rn 'opendir.*dev\|scandir.*dev\|readdir' $JNI_PATH --include="*.c" --include="*.cpp" > audit/dev-enumeration.txt

# System property reads (device fingerprinting)
grep -rn '__system_property_get\|getprop\|Build\.' $JNI_PATH --include="*.c" --include="*.cpp" > audit/system-props.txt

# Hardware ID access
grep -rn 'serial\|SERIAL\|getSerial\|USB_DEVICE_ID' $JNI_PATH --include="*.c" --include="*.cpp" > audit/hardware-ids.txt
```

#### 4.6.2 Privacy Sandbox Violation Categories

| Category | Detection Pattern | Consequence |
|----------|-------------------|-------------|
| Device Enumeration | `readdir("/dev")` | App flagged, potential removal |
| Hardware Fingerprinting | `libusb_get_device_descriptor` without permission | Privacy violation report |
| Serial Number Access | `getSerial()` pre-permission | Null return, audit log |
| Hidden Peripheral Discovery | `libusb_get_device_list()` | Process sandbox escape attempt flag |

#### 4.6.3 Deliverable: SECURITY-006-privacy-sandbox.md

Privacy Sandbox compliance assessment.

---

### 4.7 Memory Tagging Extension (MTE) Compatibility

**Objective:** Assess MTE compatibility for Tensor G5/G6 deployment

#### 4.7.1 MTE-Unsafe Pattern Detection

```bash
# Integer-to-pointer casts (MTE provenance violation)
grep -rn 'reinterpret_cast<.*\*>.*jlong\|(.*\*).*jlong\|(.*\*).*intptr_t' $JNI_PATH --include="*.cpp" > audit/mte-int-to-ptr.txt

# Pointer-to-integer casts (provenance loss)
grep -rn '(jlong).*\*\|(intptr_t).*\*\|reinterpret_cast<jlong>' $JNI_PATH --include="*.cpp" > audit/mte-ptr-to-int.txt

# memcpy with pointer arithmetic
grep -rn 'memcpy.*\+.*\*\|memmove.*\+.*\*' $JNI_PATH --include="*.c" --include="*.cpp" > audit/mte-ptr-arithmetic.txt

# Manual offset calculations
grep -rn '\[\s*.*\*.*\+\s*.*\]' $JNI_PATH --include="*.c" --include="*.cpp" > audit/mte-manual-offset.txt
```

#### 4.7.2 MTE Compatibility Assessment

| Pattern | MTE Status | Remediation |
|---------|------------|-------------|
| `jlong` to pointer cast | **FATAL** | Handle/Map registry |
| pointer to `jlong` cast | **PROVENANCE LOSS** | Return handle ID |
| `reinterpret_cast<char*>` for serialization | OK (char* aliasing rule) | None |
| `std::span` access | OK (bounds checked) | None |
| Manual `ptr + offset` | **RISKY** | `std::span` or `std::mdspan` |

#### 4.7.3 MTE Testing Configuration

```bash
# Enable MTE in app (AndroidManifest.xml)
<application android:memtagMode="sync">

# Or via adb for testing
adb shell setprop arm64.memtag.process.scopecam sync

# Monitor for MTE faults
adb logcat | grep -E "SIGSEGV|MTE|memtag"
```

#### 4.7.4 Deliverable: SECURITY-007-mte-compatibility.md

MTE compatibility assessment with test configuration.

---

### 4.8 Foreground Service Requirements

**Objective:** Document FGS configuration for USB session persistence

#### 4.8.1 Current FGS Detection

```bash
# Find existing foreground service usage
grep -rn 'startForeground\|ForegroundService\|foregroundServiceType' $KOTLIN_PATH $JAVA_PATH --include="*.kt" --include="*.java" > audit/fgs-current.txt

# Find service declarations
grep -rn '<service' $MANIFEST_PATH > audit/service-declarations.txt
```

#### 4.8.2 Android 16 FGS Requirements for USB

**Mandatory Configuration:**

```kotlin
class UsbCameraService : Service() {

    override fun onCreate() {
        super.onCreate()

        // Create notification channel (required Android 8+)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "USB Camera",
            NotificationManager.IMPORTANCE_LOW
        )
        notificationManager.createNotificationChannel(channel)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("ScopeCam Active")
            .setContentText("USB camera connected")
            .setSmallIcon(R.drawable.ic_camera)
            .build()

        // CRITICAL: Must specify foregroundServiceType
        startForeground(NOTIFICATION_ID, notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)

        return START_STICKY
    }
}
```

#### 4.8.3 Session Continuity Timeline

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     USB SESSION LIFECYCLE (ANDROID 16)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  User opens app                                                              │
│      │                                                                       │
│      ▼                                                                       │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ App starts FGS with type=connectedDevice BEFORE opening USB             ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│      │                                                                       │
│      ▼                                                                       │
│  UsbManager.requestPermission() → User grants                                │
│      │                                                                       │
│      ▼                                                                       │
│  UsbManager.openDevice() → FD obtained                                       │
│      │                                                                       │
│      ▼                                                                       │
│  FD passed to native via JNI                                                 │
│      │                                                                       │
│      ├──────────────────────────────────────────────────────────────────────│
│      │                                                                       │
│  [Screen locks with ADP enabled]                                             │
│      │                                                                       │
│      ▼                                                                       │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ With FGS: USB data signaling CONTINUES                                  ││
│  │ Without FGS: USB data pins DISABLED → read() returns ENODEV             ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 4.8.4 Deliverable: SECURITY-008-foreground-service.md

Foreground Service configuration guide for USB session persistence.

---

### 4.9 Clang-Tidy Enforcement Configuration

**Objective:** Configure Clang-Tidy 20 Query-Based Custom Checks for JNI safety enforcement

#### 4.9.1 The Crisis of Provenance at the JNI Boundary

The `jlong` pointer casting pattern represents a **fundamental subversion of type safety** in both Java and C++. Understanding the technical hazard is essential for configuring effective enforcement.

**The Hazardous Lifecycle:**
1. **Allocation:** C++ function allocates object (`new CameraController()`)
2. **Exfiltration:** Pointer cast to `jlong` and returned to Java
3. **Storage:** Java holds `jlong` in `nativeHandle` field
4. **Re-entry:** Java passes `jlong` back to C++ JNI function
5. **Reconstitution:** C++ casts `jlong` back to pointer and dereferences

**The Overflow and Truncation Vector:**

| Memory Model | Pointer Size | jlong Size | Hazard |
|--------------|--------------|------------|--------|
| **LP64** (ARM64) | 64-bit | 64-bit | Cast preserves all bits |
| **ILP32** (ARMv7) | 32-bit | 64-bit | **TRUNCATION on reconstitution** |

**Real-World Evidence (Librealsense):**
> "problem: invalid address segfault related to query sensors cause: sensor data array copy in JNI, jlong is 64-bit but pointer could be 32-bit"

**Strict Aliasing and Undefined Behavior:**

Beyond arithmetic overflow, integer-to-pointer casts **hide provenance from the optimizer**. The compiler tracks pointer origins for optimization. When a pointer "disappears" into `jlong` and "reappears" in a different function:
- Optimizer cannot prove they are related
- May assume pointer is distinct from original allocation
- Results in **Undefined Behavior (UB)** or disabled optimizations

**MTE Interaction (Android 16):**

On Tensor G5/G6 with Memory Tagging Extension:
- Each pointer carries a 4-bit tag in the top byte (TBI)
- Memory allocations are tagged
- Integer-to-pointer casts produce pointers with **no tag**
- Result: **Immediate SIGSEGV** or silent corruption

#### 4.9.2 Clang-Tidy 20 Query-Based Custom Checks

**The Paradigm Shift:** Clang-Tidy 20 introduces `CustomChecks` - dynamic AST matchers defined in configuration files, not compiled C++ plugins.

**Significance:**
- **No Recompilation:** Logic resides in `.clang-tidy`
- **Portable Policy:** Checked into version control with code
- **Complex Logic:** Full Clang AST power (not regex)
- **Context-Sensitive:** Can distinguish `jlong` as timestamp (valid) vs pointer (invalid)

#### 4.9.3 Designing the JNI Boundary Matcher

**Component 1: Defining the JNI Boundary**

Two patterns identify JNI functions:

**Pattern A: Java_ Naming Convention**
```
functionDecl(matchesName("^::Java_"))
```

**Pattern B: RegisterNatives (no Java_ prefix)**
```
functionDecl(hasParameter(0, hasType(pointsTo(typedefNameDecl(hasName("JNIEnv"))))))
```

**Component 2: Detecting the Forbidden Operation**

We must catch ALL cast styles:
- C-Style: `(MyObject*)handle` → `cStyleCastExpr`
- reinterpret_cast: `reinterpret_cast<MyObject*>(handle)` → `cxxReinterpretCastExpr`

**Component 3: The Intermediate intptr_t Evasion**

Developers may try to bypass with:
```cpp
reinterpret_cast<void*>((intptr_t)myJLong)  // Evasion attempt
```

The inner cast `jlong → intptr_t` is **exactly where truncation occurs** on ILP32. We must flag this pattern explicitly.

#### 4.9.4 The Complete AST Matcher Query

```lisp
explicitCastExpr(
  hasSourceExpression(ignoringParenImpCasts(hasType(asString("jlong")))),
  anyOf(
    hasDestinationType(pointerType()),
    hasDestinationType(asString("intptr_t")),
    hasDestinationType(asString("uintptr_t"))
  ),
  hasAncestor(
    functionDecl(
      anyOf(
        matchesName("^::Java_"),
        hasParameter(0, hasType(pointsTo(typedefNameDecl(hasName("JNIEnv")))))
      )
    )
  )
).bind("jni_raw_pointer_cast")
```

**Matcher Analysis:**

| Component | Purpose |
|-----------|---------|
| `explicitCastExpr` | Catches both C-style and C++ casts |
| `ignoringParenImpCasts` | Catches "clever" parentheses hiding |
| `asString("jlong")` | Matches typedef name (intent to interface with Java) |
| `anyOf(pointerType(), intptr_t, uintptr_t)` | Catches direct and evasion patterns |
| `hasAncestor(functionDecl(...))` | Scopes to JNI context only |
| `.bind("jni_raw_pointer_cast")` | Tags for diagnostic emission |

#### 4.9.5 The Complete .clang-tidy Configuration

```yaml
# .clang-tidy - JNI Memory Safety Enforcement for Android 16
---
Checks: >
  -*,
  bugprone-*,
  cert-*,
  cppcoreguidelines-*,
  modernize-*,
  performance-*,
  jni-no-raw-pointer-cast,
  jni-no-direct-device-access,
  jni-no-raw-storage-path

# Clang-Tidy 20 Query-Based Custom Checks
CustomChecks:
  # Check 1: Prohibit jlong to pointer casts in JNI functions
  - Name: 'jni-no-raw-pointer-cast'
    Query: >
      match
      explicitCastExpr(
        hasSourceExpression(ignoringParenImpCasts(hasType(asString("jlong")))),
        anyOf(
          hasDestinationType(pointerType()),
          hasDestinationType(asString("intptr_t")),
          hasDestinationType(asString("uintptr_t"))
        ),
        hasAncestor(
          functionDecl(
            anyOf(
              matchesName("^::Java_"),
              hasParameter(0, hasType(pointsTo(typedefNameDecl(hasName("JNIEnv")))))
            )
          )
        )
      ).bind("jni_raw_pointer_cast")
    Diagnostic:
      - BindName: 'jni_raw_pointer_cast'
        Message: >
          CRITICAL SECURITY VIOLATION: Direct cast from 'jlong' to pointer/intptr_t
          detected in JNI function. This pattern causes: (1) 32-bit truncation overflow
          on ILP32/ARMv7, (2) MTE violations on ARMv9/Tensor G5/G6, (3) Pointer
          provenance loss causing UB. Implement Handle/Map registry pattern:
          CameraRegistry::Get(handle) instead of reinterpret_cast.
        Level: Error

  # Check 2: Prohibit direct libusb device access (Privacy Sandbox violation)
  - Name: 'jni-no-direct-device-access'
    Query: >
      match
      callExpr(
        callee(
          functionDecl(
            anyOf(
              hasName("libusb_open"),
              hasName("libusb_get_device_list"),
              hasName("libusb_open_device_with_vid_pid"),
              hasName("uvc_find_device"),
              hasName("uvc_get_device_list"),
              hasName("uvc_open")
            )
          )
        )
      ).bind("direct_device_access")
    Diagnostic:
      - BindName: 'direct_device_access'
        Message: >
          PROHIBITED: Direct USB device access violates Android 16 Privacy Sandbox.
          This triggers "Hidden Hardware Access" flag and potential app store rejection.
          Use FD injection: receive FileDescriptor from UsbDeviceConnection in managed
          code, then call libusb_wrap_sys_device() in native code.
        Level: Error

  # Check 3: Prohibit raw /sdcard/ path access (Scoped Storage violation)
  - Name: 'jni-no-raw-storage-path'
    Query: >
      match
      callExpr(
        callee(functionDecl(hasName("fopen"))),
        hasArgument(0,
          stringLiteral(
            anyOf(
              hasSubstring("/sdcard"),
              hasSubstring("/storage/emulated"),
              hasSubstring("/mnt/sdcard")
            )
          )
        )
      ).bind("raw_storage_access")
    Diagnostic:
      - BindName: 'raw_storage_access'
        Message: >
          PROHIBITED: Raw external storage path access blocked by Scoped Storage.
          fopen("/sdcard/...") returns NULL with EACCES on Android 16.
          Use FD injection: receive FileDescriptor from SAF/MediaStore in Kotlin,
          pass to native via JNI, use write(fd, ...) instead of fopen().
        Level: Error

...
```

#### 4.9.6 Edge Case Validation

| Test Case | Detection Result |
|-----------|------------------|
| `(MyObj*)handle` in `Java_*` function | ✓ Detected |
| `reinterpret_cast<MyObj*>(handle)` in RegisterNatives | ✓ Detected (JNIEnv* param) |
| `(void*)(intptr_t)handle` evasion | ✓ Detected (intptr_t dest) |
| `(MyObj*)arr` where arr is `jlong*` | ✓ Detected (source is jlong) |
| `(void*)value` in non-JNI utility | ✗ Ignored (no JNI ancestor) |
| `libusb_open()` anywhere | ✓ Detected (global prohibition) |

#### 4.9.7 Build System Integration

**CMake Integration:**
```cmake
# CMakeLists.txt - Enable Clang-Tidy enforcement
set(CMAKE_CXX_CLANG_TIDY
    "clang-tidy"
    "-config-file=${CMAKE_SOURCE_DIR}/.clang-tidy"
    "-warnings-as-errors=jni-no-raw-pointer-cast,jni-no-direct-device-access,jni-no-raw-storage-path"
)

# For NDK builds
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Werror=int-to-pointer-cast")
```

**CI/CD Pipeline (GitHub Actions):**
```yaml
name: JNI Security Enforcement
on: [push, pull_request]

jobs:
  clang-tidy-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Clang-Tidy 20
        run: |
          wget https://apt.llvm.org/llvm.sh
          chmod +x llvm.sh
          sudo ./llvm.sh 20

      - name: Configure with compile_commands.json
        run: cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

      - name: Run Clang-Tidy (Parallel)
        run: |
          run-clang-tidy-20 -p build/ \
            -config-file=.clang-tidy \
            -j$(nproc) \
            src/main/jni/

      - name: Fail on violations
        run: |
          # run-clang-tidy returns non-zero on Error-level findings
          # This blocks merge of unsafe JNI code
```

**Legacy Codebase Handling:**

For existing codebases with violations:
1. Run `clang-tidy` and export warnings to baseline file
2. Use `clang-tidy-diff.py` for strict enforcement on changed lines only
3. **DISCOURAGED:** `// NOLINT(jni-no-raw-pointer-cast)` suppression

#### 4.9.8 Deliverable: SECURITY-009-clang-tidy-config/

Directory containing:
- `.clang-tidy` - Complete configuration with all three custom checks
- `CMakeLists.txt.example` - Build system integration
- `ci-workflow.yml` - GitHub Actions pipeline
- `baseline.txt.example` - Legacy codebase migration strategy

---

### 4.10 Security Threat Model

**Objective:** Document attack surface and mitigations

#### 4.10.1 Threat Categories

| Threat | Vector | Mitigation |
|--------|--------|------------|
| **T1:** Stale Handle Exploitation | Attacker passes invalid/freed handle ID | HandleMap lookup returns error |
| **T2:** 32-bit Truncation | Large jlong value on ILP32 | HandleMap (ID is never a pointer) |
| **T3:** MTE Bypass | Integer-to-pointer to evade tagging | Clang-Tidy enforcement blocks pattern |
| **T4:** USB Privilege Escalation | Native code opens arbitrary devices | FD injection (framework controls access) |
| **T5:** Storage Path Traversal | Native code writes outside sandbox | FD injection (framework controls paths) |
| **T6:** Session Hijacking | Background service steals USB | ADP hardware lockout when screen locks |

#### 4.10.2 Attack Surface Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ATTACK SURFACE MODEL                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  External Inputs (Untrusted)                                                 │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  USB Device Data         → Validate in native (libusb)                 │ │
│  │  Java Handle IDs         → Lookup in HandleMap (never cast)            │ │
│  │  File URIs from SAF      → Framework validates, native receives FD     │ │
│  │  Intent Extras           → Validate in Kotlin before JNI               │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  Trust Boundaries                                                            │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                                                                        │ │
│  │  [Java/Kotlin]  ──── JNI ────  [Native C++]                           │ │
│  │       │                              │                                 │ │
│  │       │   Handle IDs (not ptrs)      │                                 │ │
│  │       │   File Descriptors           │                                 │ │
│  │       │   Primitive values           │                                 │ │
│  │       │                              │                                 │ │
│  │       │   ❌ Raw pointers            │                                 │ │
│  │       │   ❌ File paths              │                                 │ │
│  │       │   ❌ Device names            │                                 │ │
│  │                                                                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 4.10.3 Deliverable: SECURITY-010-threat-model.md

Complete security threat model documentation.

---

## 5. Migration Architecture

### 5.1 The Handle/Map Pattern: Theoretical Foundation

**Why This Pattern is Mandatory:**

The Handle/Map (Registry) pattern is the **industry-standard remediation** for the jlong pointer hazard. It fundamentally changes the semantics of the Java-held value.

| Feature | Raw Pointer Pattern | Handle/Map Pattern |
|---------|--------------------|--------------------|
| Java Type | `long` (64-bit int) | `long` (64-bit int) |
| C++ Storage | None (stateless) | `std::map<jlong, void*>` |
| Performance | Zero-cost (CPU instruction) | O(1) with HashMap |
| Safety | Low: Segfaults on invalid ptr | High: Exception on invalid ID |
| 32-bit Support | **Dangerous:** Truncation risk | Safe: ID is just a number |
| MTE Compatibility | **Fatal:** No provenance | Safe: Pointer from map has provenance |
| Clang-Tidy | Violation (flagged) | Compliant |

**The Provenance Preservation:**

When using Handle/Map, the pointer returned by `Registry::Get()` **has valid provenance** because:
1. It comes from the map
2. The map got it from `new` (or `make_unique`)
3. The optimizer can trace this chain
4. MTE tags are preserved through the map storage

### 5.2 Handle/Map Registry Implementation (C++23)

```cpp
// CameraRegistry.h - Thread-safe handle management for Android 16
// Compliant with MTE, ILP32/LP64, and Clang-Tidy enforcement

#pragma once
#include <atomic>
#include <expected>
#include <memory>
#include <shared_mutex>
#include <unordered_map>
#include <string>
#include <jni.h>

class UVCCamera;  // Forward declaration

/**
 * @brief Thread-safe registry for native camera objects.
 *
 * This registry implements the Handle/Map pattern required by Android 16:
 * - No jlong-to-pointer casts (MTE compliant)
 * - No 32-bit truncation risk (ILP32 safe)
 * - Graceful handling of invalid/stale handles
 * - Pointer provenance preserved for optimizer
 *
 * @note Handle IDs are monotonically increasing and never reused,
 *       preventing ABA problems with stale handles.
 */
class CameraRegistry {
public:
    /**
     * @brief Register a new camera, returns handle ID (NOT a pointer).
     *
     * @param camera Unique ownership of camera object
     * @return jlong Handle ID for Java to store
     *
     * @note The returned jlong is an opaque identifier, not a memory address.
     *       This is the critical distinction that makes the pattern safe.
     */
    static jlong Register(std::unique_ptr<UVCCamera> camera) {
        std::unique_lock lock(mutex_);

        // Monotonically increasing ID prevents ABA problem
        // Even if handle 5 is unregistered, it will never be reused
        jlong id = next_id_.fetch_add(1, std::memory_order_relaxed);

        instances_[id] = std::move(camera);
        return id;
    }

    /**
     * @brief Lookup camera by handle ID (safe - no pointer cast).
     *
     * @param id Handle ID from Java
     * @return std::expected with pointer on success, error message on failure
     *
     * @note The returned pointer HAS VALID PROVENANCE because it comes
     *       from the map, which got it from make_unique. This satisfies
     *       both MTE tag verification and compiler provenance tracking.
     */
    static std::expected<UVCCamera*, std::string> Get(jlong id) {
        std::shared_lock lock(mutex_);

        auto it = instances_.find(id);
        if (it == instances_.end()) {
            return std::unexpected(
                "Invalid camera handle: " + std::to_string(id) +
                ". Handle may have been released or was never valid."
            );
        }

        // Pointer provenance is preserved: map -> unique_ptr -> raw ptr
        return it->second.get();
    }

    /**
     * @brief Unregister and destroy camera.
     *
     * @param id Handle ID to unregister
     * @return true if handle existed and was removed, false otherwise
     *
     * @note After this call, any subsequent Get(id) will fail gracefully
     *       with an error message instead of segfaulting.
     */
    static bool Unregister(jlong id) {
        std::unique_lock lock(mutex_);
        return instances_.erase(id) > 0;
    }

    /**
     * @brief Check if handle is valid without returning pointer.
     *
     * @param id Handle ID to check
     * @return true if handle exists in registry
     *
     * @note Useful for validation without accessing the object.
     */
    static bool IsValid(jlong id) {
        std::shared_lock lock(mutex_);
        return instances_.contains(id);
    }

    /**
     * @brief Get count of active handles (for debugging/metrics).
     */
    static size_t ActiveCount() {
        std::shared_lock lock(mutex_);
        return instances_.size();
    }

private:
    // Start at 1 so that 0 can be used as "invalid handle" sentinel
    static inline std::atomic<jlong> next_id_{1};

    // The map preserves pointer provenance for MTE compliance
    static inline std::unordered_map<jlong, std::unique_ptr<UVCCamera>> instances_;

    // shared_mutex allows concurrent reads (Get) with exclusive writes (Register/Unregister)
    static inline std::shared_mutex mutex_;
};
```

### 5.3 JNI Function Migration Examples

**Before (PROHIBITED - Triggers Clang-Tidy Error):**

```cpp
// This code will fail Clang-Tidy jni-no-raw-pointer-cast check
JNIEXPORT void JNICALL Java_com_scopecam_Camera_nativeStartPreview(
    JNIEnv* env, jobject thiz, jlong handle, jobject surface)
{
    // ❌ CRITICAL VIOLATION: Direct cast from jlong to pointer
    // - MTE: Pointer has no tag → SIGSEGV on Tensor G5/G6
    // - ILP32: Truncation if handle > 4GB (unlikely but possible)
    // - Provenance: Optimizer cannot track pointer origin → UB
    auto* camera = reinterpret_cast<UVCCamera*>(handle);
    camera->startPreview(ANativeWindow_fromSurface(env, surface));
}
```

**After (COMPLIANT - Handle/Map Pattern):**

```cpp
// This code passes Clang-Tidy and is safe on all architectures
JNIEXPORT void JNICALL Java_com_scopecam_Camera_nativeStartPreview(
    JNIEnv* env, jobject thiz, jlong handle, jobject surface)
{
    // ✓ COMPLIANT: Lookup returns pointer with valid provenance
    auto result = CameraRegistry::Get(handle);

    if (!result) {
        // Graceful failure instead of segfault
        ThrowJniException(env, "java/lang/IllegalStateException",
                          result.error().c_str());
        return;
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    if (!window) {
        ThrowJniException(env, "java/lang/IllegalArgumentException",
                          "Invalid surface");
        return;
    }

    // Pointer from registry has valid MTE tag and provenance
    (*result)->startPreview(window);
}
```

### 5.4 Complete FD Injection + Handle/Map Architecture

```cpp
// The complete compliant architecture for Android 16

// ==================== ALLOCATION (Java calls native) ====================

JNIEXPORT jlong JNICALL Java_com_scopecam_Camera_nativeOpen(
    JNIEnv* env, jobject thiz, jint fd)
{
    // fd comes from UsbDeviceConnection.getFileDescriptor()
    // Native code NEVER opens devices directly

    // Initialize libusb context
    libusb_context* ctx;
    int ret = libusb_init_context(&ctx, nullptr, 0);
    if (ret < 0) {
        ThrowJniException(env, "java/io/IOException",
                          libusb_strerror(static_cast<libusb_error>(ret)));
        return 0;  // 0 = invalid handle
    }

    // ✓ FD INJECTION: Use framework-provided FD, not direct open
    libusb_device_handle* usb_handle;
    ret = libusb_wrap_sys_device(ctx, static_cast<intptr_t>(fd), &usb_handle);
    if (ret < 0) {
        libusb_exit(ctx);
        ThrowJniException(env, "java/io/IOException",
                          "Failed to wrap USB file descriptor");
        return 0;
    }

    // Create camera with injected handle
    auto camera = std::make_unique<UVCCamera>(ctx, usb_handle);

    // ✓ HANDLE/MAP: Return opaque ID, not pointer
    return CameraRegistry::Register(std::move(camera));
}

// ==================== USAGE (Java calls native methods) ====================

JNIEXPORT void JNICALL Java_com_scopecam_Camera_nativeSetExposure(
    JNIEnv* env, jobject thiz, jlong handle, jint exposure)
{
    // ✓ COMPLIANT: Lookup instead of cast
    auto result = CameraRegistry::Get(handle);
    if (!result) {
        ThrowJniException(env, "java/lang/IllegalStateException",
                          result.error().c_str());
        return;
    }

    (*result)->setExposure(exposure);
}

// ==================== DEALLOCATION (Java calls native) ====================

JNIEXPORT void JNICALL Java_com_scopecam_Camera_nativeClose(
    JNIEnv* env, jobject thiz, jlong handle)
{
    // Unregister destroys the unique_ptr, which cleans up resources
    if (!CameraRegistry::Unregister(handle)) {
        // Handle was already closed or never valid - log but don't throw
        __android_log_print(ANDROID_LOG_WARN, "ScopeCam",
                            "nativeClose called with invalid handle: %lld",
                            static_cast<long long>(handle));
    }
}
```

### 5.5 Performance Considerations

**"But map lookups are slower than pointer casts!"**

| Operation | Latency |
|-----------|---------|
| JNI call overhead | 10-20ns |
| `std::unordered_map::find()` | 5-15ns |
| `reinterpret_cast` | <1ns |
| **Total with Handle/Map** | 15-35ns |
| **Total with raw cast** | 10-21ns |

**Analysis:** The Handle/Map adds ~5-15ns overhead. In the context of:
- JNI transition: Already 10-20ns
- USB I/O: Microseconds to milliseconds
- Frame processing: Milliseconds

The overhead is **negligible** compared to actual work.

**For High-Performance Paths:**
- Use `CriticalNative` methods (skip JNI overhead entirely)
- Cache the pointer on C++ side after initial lookup
- Use `DirectByteBuffer` for bulk data transfer (JVM-sanctioned raw memory sharing)

### 5.6 Complete Migration Checklist

| Component | Legacy Pattern | Compliant Pattern | Status |
|-----------|---------------|-------------------|--------|
| USB Access | `libusb_open()` | `libusb_wrap_sys_device(fd)` | ☐ |
| Handle Storage | `jlong = (jlong)ptr` | `jlong = Registry::Register()` | ☐ |
| Handle Retrieval | `(MyObj*)jlong` | `Registry::Get(jlong)` | ☐ |
| Handle Validation | Segfault on invalid | `Registry::IsValid()` or error return | ☐ |
| Storage Write | `fopen("/sdcard/...")` | `write(fd)` from SAF | ☐ |
| Background USB | None | FGS `connectedDevice` | ☐ |
| Permission | Runtime only | Manifest + runtime | ☐ |
| Clang-Tidy | Not configured | All 3 custom checks enabled | ☐ |

---

## 6. Deliverables

### 6.1 Deliverable Checklist

| ID | Deliverable | Format | Status |
|----|-------------|--------|--------|
| SECURITY-001 | USB Access Patterns | Markdown | ☐ |
| SECURITY-002 | FD Injection Assessment | Markdown | ☐ |
| SECURITY-003 | JNI Safety Catalog | Markdown | ☐ |
| SECURITY-004 | Scoped Storage | Markdown | ☐ |
| SECURITY-005 | Manifest Audit | Markdown | ☐ |
| SECURITY-006 | Privacy Sandbox | Markdown | ☐ |
| SECURITY-007 | MTE Compatibility | Markdown | ☐ |
| SECURITY-008 | Foreground Service | Markdown | ☐ |
| SECURITY-009 | Clang-Tidy Config | Directory | ☐ |
| SECURITY-010 | Threat Model | Markdown | ☐ |
| SECURITY-011 | Master Catalog | CSV | ☐ |

### 6.2 Deliverable Output Structure

```
audit/
├── AUDIT-004-android-security.md          # This document
├── SECURITY-001-usb-access.md
├── SECURITY-002-fd-injection.md
├── SECURITY-003-jni-safety.md
├── SECURITY-004-scoped-storage.md
├── SECURITY-005-manifest.md
├── SECURITY-006-privacy-sandbox.md
├── SECURITY-007-mte-compatibility.md
├── SECURITY-008-foreground-service.md
├── SECURITY-009-clang-tidy-config/
│   ├── .clang-tidy
│   ├── CMakeLists.txt.example
│   └── ci-workflow.yml
├── SECURITY-010-threat-model.md
├── SECURITY-011-master-catalog.csv
└── raw/
    ├── libusb-direct-access.txt
    ├── jlong-cstyle-cast.txt
    ├── jlong-reinterpret-cast.txt
    ├── raw-storage-paths.txt
    └── [all other grep outputs]
```

---

## 7. Verification Criteria

### 7.1 Completeness Verification

| Criterion | Verification Method | Pass/Fail |
|-----------|-------------------|-----------|
| All direct USB access identified | Compare grep to SECURITY-001 | ☐ |
| All JNI pointer casts catalogued | Compare grep to SECURITY-003 | ☐ |
| All raw storage paths identified | Compare grep to SECURITY-004 | ☐ |
| Manifest has required permissions | Diff against template | ☐ |
| Clang-Tidy config validates | Run on test violations | ☐ |

### 7.2 Quality Gates

| Gate | Requirement | Threshold |
|------|-------------|-----------|
| Completeness | All deliverables produced | 11/11 |
| Clang-Tidy | Zero JNI pointer cast violations | 0 errors |
| Manifest | All required permissions declared | 100% |
| FD Injection | No direct device access patterns | 0 violations |

### 7.3 Security Validation Tests

```bash
# Test 1: Clang-Tidy enforcement
clang-tidy --config-file=.clang-tidy src/main/jni/*.cpp 2>&1 | grep -c "jni-no-raw-pointer-cast"
# Expected: 0 (all violations fixed)

# Test 2: MTE simulation
adb shell setprop arm64.memtag.process.scopecam sync
adb shell am start com.scopecam/.MainActivity
adb logcat | grep -E "SIGSEGV|MTE"
# Expected: No MTE faults

# Test 3: Scoped Storage enforcement
adb shell run-as com.scopecam ls /sdcard/DCIM/
# Expected: Permission denied (correct behavior)
```

---

## 8. Agent Instructions

### 8.1 Investigation-First Methodology

**CRITICAL:** Before documenting ANY security violation, agents MUST:

1. **SHOW** the grep/search command executed
2. **SHOW** the raw output (first 20 lines if large)
3. **CLASSIFY** using the violation taxonomy
4. **ASSESS** Android 16 impact
5. **DOCUMENT** migration requirement
6. **THEN** catalog in standard format

### 8.2 Execution Order

```
1. Verify AUDIT-001, 002, 003 artifacts available
2. Execute USB access audit (Task 4.1)
3. Execute FD injection analysis (Task 4.2)
4. Execute JNI safety assessment (Task 4.3)
5. Execute Scoped Storage audit (Task 4.4)
6. Execute manifest permission audit (Task 4.5)
7. Execute Privacy Sandbox check (Task 4.6)
8. Execute MTE compatibility assessment (Task 4.7)
9. Document FGS requirements (Task 4.8)
10. Generate Clang-Tidy config (Task 4.9)
11. Document threat model (Task 4.10)
12. Consolidate master catalog (Section 5)
13. Verify all deliverables (Section 7)
```

### 8.3 Violation Classification Rules

| If you find... | Classify as... | Risk default... |
|----------------|----------------|-----------------|
| `libusb_open()` | DIRECT_DEVICE_ACCESS | CRITICAL |
| `libusb_get_device_list()` | HIDDEN_HARDWARE_DISCOVERY | CRITICAL |
| `reinterpret_cast<*>(jlong)` | JNI_POINTER_CAST | CRITICAL |
| `(MyObj*)handle` | JNI_POINTER_CAST | CRITICAL |
| `fopen("/sdcard/...")` | RAW_STORAGE_ACCESS | HIGH |
| Missing FGS `connectedDevice` | FGS_MISCONFIGURATION | HIGH |
| Missing `FOREGROUND_SERVICE_CONNECTED_DEVICE` | MANIFEST_INCOMPLETE | HIGH |

### 8.4 Error Handling

| Error | Recovery Action |
|-------|----------------|
| Clang-Tidy 20 not available | Document requirement, provide config for future |
| Manifest not accessible | Request file, document gap |
| libusb version uncertain | Flag for runtime verification |
| Complex macro-hidden patterns | Expand manually, document |

### 8.5 Progress Reporting

```
[AUDIT-004] Task 4.1 Complete: USB Access Patterns
  - libusb_open calls: N (CRITICAL)
  - libusb_get_device_list calls: N (CRITICAL)
  - FD injection ready: YES/NO

[AUDIT-004] Task 4.3 Complete: JNI Safety
  - jlong pointer casts: N (CRITICAL)
  - Handle/Map pattern used: YES/NO
  - MTE compatible: YES/NO
```

---

## Appendix A: Android 16 Permission Reference

### A.1 USB Host Permissions

```xml
<!-- Required for USB host functionality -->
<uses-feature android:name="android.hardware.usb.host" android:required="true"/>

<!-- Runtime permission request not needed - UsbManager handles this -->
<!-- But must declare for manifest merging -->
```

### A.2 Foreground Service Permissions

```xml
<!-- Base FGS permission -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>

<!-- Type-specific permission (Android 14+) -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>

<!-- Notification permission (Android 13+) -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

### A.3 Storage Permissions (Android 16)

```xml
<!-- For MediaStore access -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>

<!-- For SAF - no permission needed, user selects location -->

<!-- DEPRECATED - DO NOT USE -->
<!-- <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/> -->
<!-- <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/> -->
```

---

## Appendix B: libusb FD Injection API

### B.1 libusb Version Requirements

```c
// Minimum version for wrap_sys_device
#if LIBUSB_API_VERSION >= 0x01000107  // 1.0.23+
    // libusb_wrap_sys_device available
#else
    #error "libusb 1.0.23+ required for Android 16 FD injection"
#endif
```

### B.2 FD Injection Pattern

```c
// Initialize libusb context
libusb_context* ctx;
int ret = libusb_init_context(&ctx, NULL, 0);
if (ret < 0) return ret;

// Wrap the FD provided by Android framework
// fd comes from UsbDeviceConnection.getFileDescriptor()
libusb_device_handle* handle;
ret = libusb_wrap_sys_device(ctx, (intptr_t)fd, &handle);
if (ret < 0) {
    libusb_exit(ctx);
    return ret;
}

// Now use handle normally
// NOTE: Do NOT call libusb_close() - Android owns the FD
// Just call libusb_exit() when done
```

---

## Appendix C: Handle/Map Pattern Reference

### C.1 Type-Erased Registry (Multi-Type Support)

```cpp
// For libraries managing multiple native object types

class NativeRegistry {
public:
    template<typename T>
    static jlong Register(std::unique_ptr<T> obj) {
        std::unique_lock lock(mutex_);
        jlong id = next_id_++;
        instances_[id] = Entry{
            std::unique_ptr<void, void(*)(void*)>(
                obj.release(),
                &Destructor<T>
            )
        };
        return id;
    }

    template<typename T>
    static T* Get(jlong id) {
        std::shared_lock lock(mutex_);
        auto it = instances_.find(id);
        if (it == instances_.end()) return nullptr;
        return static_cast<T*>(it->second.ptr.get());
    }

    static void Unregister(jlong id) {
        std::unique_lock lock(mutex_);
        instances_.erase(id);
    }

private:
    struct Entry {
        std::unique_ptr<void, void(*)(void*)> ptr;
    };

    template<typename T>
    static void Destructor(void* p) {
        delete static_cast<T*>(p);
    }

    static inline std::atomic<jlong> next_id_{1};
    static inline std::unordered_map<jlong, Entry> instances_;
    static inline std::shared_mutex mutex_;
};
```

---

## Appendix D: JNI Type Width Reference

### D.1 Critical Type Width Comparison

| Type | Size (ILP32 / ARMv7) | Size (LP64 / ARM64) | Risk of Cast (`jlong → void*`) |
|------|----------------------|---------------------|-------------------------------|
| `jlong` | 64-bit | 64-bit | Safe container |
| `jint` | 32-bit | 32-bit | **Too small** for 64-bit pointers |
| `void*` | 32-bit | 64-bit | **Truncation** on 32-bit if jlong > 4GB |
| `intptr_t` | 32-bit | 64-bit | **Truncation** on 32-bit if jlong > 4GB |
| `uintptr_t` | 32-bit | 64-bit | **Truncation** on 32-bit if jlong > 4GB |

### D.2 The Truncation Hazard Explained

**Scenario:** 64-bit server sends pointer value to 32-bit Android client via IPC

```cpp
// Server (LP64): Pointer is 0x0000_7FFF_1234_5678 (within 47-bit address space)
jlong handle = reinterpret_cast<jlong>(ptr);  // handle = 0x7FFF12345678

// Client (ILP32): Receives handle, casts to pointer
void* ptr = reinterpret_cast<void*>(handle);
// ptr = 0x12345678 (upper 32 bits LOST)
// Dereference → SEGFAULT or worse: valid but WRONG address
```

**Why Handle/Map Solves This:**
- Handle ID is *never* an address
- ID can be any 64-bit integer value
- Architecture of sender/receiver is irrelevant
- ID → Pointer lookup happens locally with correct pointer width

### D.3 MTE Tag Structure (ARMv9)

```
64-bit pointer on ARMv9 with MTE:
┌────────┬────────────────────────────────────────────────────────────┐
│ Tag(4) │                    Address (60 bits)                       │
│ bits   │                                                            │
└────────┴────────────────────────────────────────────────────────────┘
   TBI                              Virtual Address

When integer is cast to pointer:
┌────────┬────────────────────────────────────────────────────────────┐
│ 0000   │              Integer value (no tag information)            │
└────────┴────────────────────────────────────────────────────────────┘
   ↑
   No MTE tag → Memory access triggers SIGSEGV
```

---

## Appendix E: Security Catalog CSV Schema

```csv
id,location,file,line,category,pattern,android16_impact,migration,risk,effort,mte_impact,status,notes
USB-001,libuvc/device.c,device.c,342,DIRECT_DEVICE_ACCESS,libusb_open(),Privacy Sandbox flag,libusb_wrap_sys_device(),Critical,High,N/A,Pending,"Main device open"
JNI-001,UVCCamera.cpp,UVCCamera.cpp,156,JNI_POINTER_CAST,reinterpret_cast<UVCCamera*>,MTE violation + Truncation,Handle/Map,Critical,Medium,SIGSEGV,Pending,"Preview start"
JNI-002,UVCCamera.cpp,UVCCamera.cpp,89,JNI_POINTER_CAST,(intptr_t)handle,32-bit truncation,Handle/Map,Critical,Medium,Provenance loss,Pending,"intptr_t evasion"
STOR-001,capture.cpp,capture.cpp,234,RAW_STORAGE_ACCESS,fopen("/sdcard/..."),EACCES,SAF + FD injection,High,Medium,N/A,Pending,"Frame save"
FGS-001,AndroidManifest.xml,AndroidManifest.xml,45,FGS_MISCONFIGURATION,Missing connectedDevice,Connection dropped on lock,Add FGS type,High,Low,N/A,Pending,"USB session"
```

---

## Appendix F: Privacy Sandbox "Hidden Hardware Access" Triggers

### F.1 Patterns That Trigger Flags

| Pattern | Detection Method | Consequence |
|---------|------------------|-------------|
| `opendir("/dev")` | syscall monitoring | App flagged for review |
| `libusb_get_device_list()` | Library signature | "Unauthorized Peripheral Discovery" |
| `glob("/dev/video*")` | File access audit | Privacy violation report |
| `inotify_add_watch("/dev/bus/usb")` | inotify monitoring | Sandbox escape attempt flag |
| `libusb_open()` without prior permission | USB subsystem hooks | SecurityException |

### F.2 Compliant Alternatives

| Prohibited Pattern | Compliant Alternative |
|-------------------|----------------------|
| Enumerate USB devices in native | `UsbManager.getDeviceList()` in Kotlin |
| Open device by path | `UsbDeviceConnection.getFileDescriptor()` |
| Scan for video devices | `Camera2 API` or `CameraManager` |
| Monitor for USB hotplug | `BroadcastReceiver` for `USB_DEVICE_ATTACHED` |

---

## Appendix G: Kotlin Foreground Service Template

```kotlin
/**
 * Android 16 compliant USB Foreground Service for ScopeCam.
 *
 * This service type (connectedDevice) is REQUIRED for USB session
 * persistence when the screen locks under Advanced Data Protection.
 */
class UsbCameraService : Service() {

    companion object {
        private const val CHANNEL_ID = "scopecam_usb_channel"
        private const val NOTIFICATION_ID = 1001
    }

    private lateinit var notificationManager: NotificationManager

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(NotificationManager::class.java)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = createNotification()

        // CRITICAL: Must specify foregroundServiceType for Android 14+
        // Without this, USB connection WILL be dropped when screen locks
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "USB Camera Connection",
            NotificationManager.IMPORTANCE_LOW  // Low = no sound, minimal intrusion
        ).apply {
            description = "Maintains USB camera connection when screen is off"
            setShowBadge(false)
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun createNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("ScopeCam Active")
            .setContentText("USB microscope connected")
            .setSmallIcon(R.drawable.ic_camera)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }
}
```

**Manifest Declaration:**
```xml
<service
    android:name=".UsbCameraService"
    android:foregroundServiceType="connectedDevice"
    android:exported="false">
</service>
```

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 0.1 | 2026-01-11 | Claude | Initial draft |
| 0.2 | 2026-01-11 | Claude | Enhanced Clang-Tidy AST matcher analysis, jlong provenance crisis, ILP32/LP64 truncation hazards, detailed Handle/Map implementation |

---

*End of AUDIT-004*
