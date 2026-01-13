# SECURITY-001: USB Access Pattern Inventory

**Audit:** AUDIT-004 Android Security Compliance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

| Metric | Count | Risk Level |
|--------|-------|------------|
| **Direct `libusb_open()` calls** | 3 | CRITICAL |
| **Direct `libusb_get_device_list()` calls** | 1 | CRITICAL |
| **Direct `uvc_open()` calls** | 1 | HIGH |
| **Device enumeration (`opendir /dev`)** | 15+ | CRITICAL |
| **FD injection ready (`libusb_wrap_sys_device`)** | 0 | BLOCKER |

**Overall Assessment:** NOT COMPLIANT with Android 16 Zero-Trust Hardware model.

---

## Critical Findings

### USB-001: Direct libusb_open() in UVCCamera.cpp (CRITICAL)

**Location:** `lib/src/main/jni/UVCCamera/UVCCamera.cpp:466`

**Pattern:**
```cpp
result = libusb_open(mDevice->usb_dev, &usb_devh);
```

**Context:** Called during camera connection after `uvc_open()` has established the UVC device handle.

**Android 16 Violation:**
- **SELinux:** App process cannot access `/dev/bus/usb/*` directly
- **Privacy Sandbox:** Triggers "Hidden Hardware Access" flag
- **Result:** SecurityException or silent failure

**Migration Requirement:** Replace with FD injection:
```cpp
// Receive fd from Java's UsbDeviceConnection.getFileDescriptor()
result = libusb_wrap_sys_device(ctx, fd, &usb_devh);
```

---

### USB-002: Direct libusb_open() in libuvc/device.c (CRITICAL)

**Location:** `lib/src/main/jni/libuvc/src/device.c:277, 509`

**Pattern:**
```c
ret = libusb_open(dev->usb_dev, &devh->usb_devh);
```

**Context:** Core UVC device opening logic in libuvc library.

**Migration Requirement:** Modify libuvc to accept pre-opened FD:
```c
uvc_error_t uvc_open_from_fd(
    int fd,
    uvc_context_t* ctx,
    uvc_device_handle_t** devh
);
```

---

### USB-003: Direct libusb_get_device_list() (CRITICAL)

**Location:** `lib/src/main/jni/libuvc/src/device.c:603`

**Pattern:**
```c
if (libusb_get_device_list(ctx->usb_ctx, &usb_dev_list) < 0) {
```

**Context:** Device discovery in `uvc_find_device()`.

**Android 16 Violation:**
- **Privacy Sandbox:** "Unauthorized Peripheral Discovery" flag
- Native code MUST NOT enumerate USB devices

**Migration Requirement:** Remove entirely. Device discovery must happen in managed layer:
```kotlin
// Kotlin side handles discovery
val devices = usbManager.deviceList.values
    .filter { it.vendorId == targetVid && it.productId == targetPid }
```

---

### USB-004: Device Path Enumeration (CRITICAL)

**Location:** `lib/src/main/jni/libusb/libusb/os/android_usbfs.c`

**Patterns Found:**
```c
dir = opendir(dirname);              // Line 318
while ((entry = readdir(dir))) {     // Line 322
dir = opendir(path);                 // Line 353
DIR *buses = opendir(usbfs_path);    // Line 1542
```

**Context:** libusb's Android backend scans `/dev/bus/usb/*` directories.

**Android 16 Impact:**
- SELinux denies these operations
- Privacy Sandbox flags "Hidden Hardware Access"
- Enumeration returns empty results

**Note:** This is within the libusb library. The custom `libusb_init2(usbfs)` function attempts to work around this by accepting a usbfs path, but this approach is deprecated.

---

## Current Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     CURRENT USB ACCESS FLOW (PROHIBITED)                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Java/Kotlin Layer                                                           │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  USBMonitor.requestPermission(device)     // ✓ COMPLIANT                │ │
│  │  UsbManager.openDevice(device)            // ✓ COMPLIANT                │ │
│  │  connection.getFileDescriptor()           // ✓ COMPLIANT                │ │
│  │                                                                         │ │
│  │  nativeConnect(vendorId, productId, fd, busNum, devAddr, usbfs)        │ │
│  │                    ↓                                                    │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                        JNI BOUNDARY                                          │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  UVCCamera::connect()                                                  │ │
│  │      ↓                                                                  │ │
│  │  uvc_open(mDevice, &mDeviceHandle)        // ❌ USES libusb_open       │ │
│  │      ↓                                                                  │ │
│  │  libusb_open(dev->usb_dev, &usb_devh)     // ❌ DIRECT DEVICE ACCESS   │ │
│  │      ↓                                                                  │ │
│  │  open("/dev/bus/usb/...")                 // ❌ BLOCKED BY SELINUX     │ │
│  │                                                                         │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  Note: Java layer correctly uses UsbManager, but FD is NOT used by native!  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Java Layer Analysis (COMPLIANT)

The Java/Kotlin layer correctly implements USB permission flow:

**USBMonitor.java (Lines 396-424):**
```java
public void requestPermission(final UsbDevice device) {
    // ...
    if (!hasPermission(device)) {
        mUsbManager.requestPermission(device, mPermissionIntent);
    }
}
```

**UVCCamera.java (Line 234):**
```java
mCtrlBlock.getFileDescriptor()  // FD is extracted correctly
```

**Problem:** The FD is passed to native but NOT used. Native code calls `libusb_open()` which attempts direct device access.

---

## libusb Version Analysis

**Current Version:** 1.0.19 (API 0x01000103)

**Location:** `lib/src/main/jni/libusb/libusb/libusb.h:147`
```c
#define LIBUSB_API_VERSION 0x01000103
```

**Required for FD Injection:** 1.0.23+ (API 0x01000107)

**Missing APIs:**
- `libusb_wrap_sys_device()` - NOT AVAILABLE
- `libusb_init_context()` - NOT AVAILABLE
- `LIBUSB_OPTION_WEAK_AUTHORITY` - NOT AVAILABLE

**Custom Extension Found:**
```c
int libusb_init2(libusb_context **ctx, const char *usbfs);  // Line 1362
```

This is a custom Android extension that accepts a usbfs path, but does NOT implement proper FD injection.

---

## Migration Requirements

### Phase 1: Upgrade libusb (BLOCKING)

| Task | Priority | Effort |
|------|----------|--------|
| Upgrade libusb to 1.0.23+ | P0 | HIGH |
| Verify `libusb_wrap_sys_device()` availability | P0 | LOW |
| Remove device enumeration code | P1 | MEDIUM |

### Phase 2: Modify libuvc

| Task | Priority | Effort |
|------|----------|--------|
| Add `uvc_open_from_fd()` API | P0 | HIGH |
| Remove `uvc_find_device()` | P1 | MEDIUM |
| Update `uvc_init()` to accept FD | P1 | MEDIUM |

### Phase 3: Update UVCCamera

| Task | Priority | Effort |
|------|----------|--------|
| Modify `connect()` to use FD injection | P0 | MEDIUM |
| Remove `libusb_open()` calls | P0 | LOW |
| Update JNI interface to pass FD | P0 | LOW |

---

## Target Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     TARGET USB ACCESS FLOW (COMPLIANT)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Kotlin Layer                                                                │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  usbManager.requestPermission(device)    // Framework dialog           │ │
│  │      ↓                                                                  │ │
│  │  val connection = usbManager.openDevice(device)  // Framework opens   │ │
│  │      ↓                                                                  │ │
│  │  val fd = connection.fileDescriptor      // Extract FD                 │ │
│  │      ↓                                                                  │ │
│  │  nativeInitWithFd(fd)                    // Pass FD to native          │ │
│  │                                                                         │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                        JNI BOUNDARY                                          │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  nativeInitWithFd(jint fd) {                                           │ │
│  │      libusb_context* ctx;                                              │ │
│  │      libusb_init_context(&ctx, nullptr, 0);  // ✓ No device enum      │ │
│  │                                                                         │ │
│  │      libusb_device_handle* handle;                                     │ │
│  │      libusb_wrap_sys_device(ctx, fd, &handle);  // ✓ FD INJECTION     │ │
│  │                                                                         │ │
│  │      // Use handle - native code is PASSIVE                            │ │
│  │  }                                                                      │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  Native code NEVER opens devices, NEVER enumerates, ONLY receives FDs       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Raw Data References

| File | Contents |
|------|----------|
| `raw/security/libusb-direct-access.txt` | `libusb_open` pattern matches |
| `raw/security/libuvc-discovery.txt` | `uvc_open` and `uvc_find_device` matches |
| `raw/security/dev-raw-access.txt` | `/dev/bus/usb` path references |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-002** | FD injection readiness assessment |
| **SECURITY-006** | Privacy Sandbox violation details |
| **SECURITY-010** | USB privilege escalation threat model |
| **AUDIT-003-appendix-advanced.md** | Android 16 USB FD persistence (Appendix D) |

---

*End of SECURITY-001*
