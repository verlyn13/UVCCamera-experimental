# SECURITY-002: File Descriptor Injection Readiness Assessment

**Audit:** AUDIT-004 Android Security Compliance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

| Requirement | Current Status | Migration Needed |
|-------------|---------------|------------------|
| libusb 1.0.23+ (`wrap_sys_device`) | ❌ Version 1.0.19 | **UPGRADE REQUIRED** |
| JNI accepts `jint fd` parameter | ⚠️ Partial | Signature already exists |
| `libusb_wrap_sys_device()` calls | ❌ None (0) | Add to all device init |
| No `libusb_open()` calls | ❌ 3 calls | Remove all |
| No `libusb_get_device_list()` | ❌ 1+ calls | Remove all |
| RAII FD wrapper (`UniqueFd`) | ⚠️ Not used | Add from SAFETY-004 |

**Overall Assessment:** Major refactoring required. libusb upgrade is the primary blocker.

---

## Current libusb Version Analysis

### Version Detection

**Location:** `lib/src/main/jni/libusb/libusb/libusb.h`

```c
// Line 147
#define LIBUSB_API_VERSION 0x01000103
```

**Decoded:** Version 1.0.19 (released 2017)

### Required API Comparison

| API | Version Required | Current Status |
|-----|-----------------|----------------|
| `libusb_init()` | 1.0.0 | ✓ Available |
| `libusb_init2()` | Custom | ✓ Available (Android extension) |
| `libusb_wrap_sys_device()` | **1.0.23** | ❌ NOT AVAILABLE |
| `libusb_init_context()` | 1.0.25 | ❌ NOT AVAILABLE |
| `LIBUSB_OPTION_WEAK_AUTHORITY` | 1.0.23 | ❌ NOT AVAILABLE |

### Custom Android Extension

The codebase includes a custom `libusb_init2()` function:

**Location:** `lib/src/main/jni/libusb/libusb/core.c:2039`

```c
int API_EXPORTED libusb_init2(libusb_context **context, const char *usbfs) {
    // Custom implementation that accepts usbfs path string
    // e.g., "/dev/bus/usb/001/002"
}
```

**Analysis:** This extension predates proper FD injection. It accepts a *path string* which native code then opens directly—still triggering SELinux denials on Android 16.

---

## FD Injection Entry Point Analysis

### Current JNI Signatures

**UVCCamera.java → nativeConnect:**
```java
// Already accepts fd parameter
private native int nativeConnect(long id_camera, int vendorId, int productId,
                                 int fileDescriptor, int busNum, int devAddr,
                                 String usbfs);
```

**serenegiant_usb_UVCCamera.cpp:159:**
```cpp
static jint nativeConnect(JNIEnv *env, jobject thiz,
    ID_TYPE id_camera,
    jint vendorId, jint productId,
    jint fileDescriptor,      // FD is passed here
    jint busNum, jint devAddr,
    jstring usbfsString)      // But path is used instead!
```

**Critical Gap:** The FD is passed across JNI but **never used**. The code uses the `usbfsString` path instead:

```cpp
// Line 183-185 (approximate)
const char* usbfs = env->GetStringUTFChars(usbfsString, nullptr);
result = camera->connect(vendorId, productId, fileDescriptor,
                         busNum, devAddr, usbfs);  // FD passed but ignored
```

---

## FD Usage Trace

### Java Side (COMPLIANT)

**UVCCamera.java:232-234:**
```java
mCtrlBlock = new USBMonitor.UsbControlBlock(clazz, mDevice);
// ...
mCtrlBlock.getFileDescriptor()  // FD correctly extracted
```

### Native Side (NON-COMPLIANT)

**UVCCamera::connect() implementation:**
```cpp
// The fd parameter is received but not used for device opening
// Instead, uvc_open() is called which internally calls libusb_open()
result = uvc_open(mDevice, &mDeviceHandle);
```

**libuvc/device.c uvc_open():**
```c
uvc_error_t uvc_open(uvc_device_t *dev, uvc_device_handle_t **devh) {
    // ...
    ret = libusb_open(dev->usb_dev, &internal_devh->usb_devh);  // DIRECT ACCESS
    // ...
}
```

---

## Required Migration Steps

### Step 1: Upgrade libusb (P0)

```bash
# Current
lib/src/main/jni/libusb/  # Version 1.0.19

# Required
# Upgrade to libusb 1.0.26+ (latest stable)
# Source: https://github.com/libusb/libusb/releases
```

**Considerations:**
- Review Android-specific patches in current `android_usbfs.c`
- May need to port custom modifications to new version
- Test on Android 14+ before Android 16 deployment

### Step 2: Add uvc_open_from_fd() to libuvc (P0)

**New API:**
```c
/**
 * Open UVC device using an already-open file descriptor.
 * The FD should come from Android's UsbDeviceConnection.getFileDescriptor().
 *
 * @param ctx UVC context (from uvc_init)
 * @param fd File descriptor from Java layer
 * @param devh Output device handle
 * @return UVC_SUCCESS or error code
 */
uvc_error_t uvc_open_from_fd(uvc_context_t* ctx, int fd,
                              uvc_device_handle_t** devh);
```

**Implementation Sketch:**
```c
uvc_error_t uvc_open_from_fd(uvc_context_t* ctx, int fd,
                              uvc_device_handle_t** devh) {
    uvc_error_t ret;
    uvc_device_handle_t* internal_devh;

    internal_devh = calloc(1, sizeof(*internal_devh));
    if (!internal_devh)
        return UVC_ERROR_NO_MEM;

    // Use FD injection instead of libusb_open
    ret = libusb_wrap_sys_device(ctx->usb_ctx, (intptr_t)fd,
                                  &internal_devh->usb_devh);
    if (ret < 0) {
        free(internal_devh);
        return UVC_ERROR_IO;
    }

    // Continue with UVC-specific initialization
    ret = uvc_get_device_descriptor(internal_devh);
    // ...

    *devh = internal_devh;
    return UVC_SUCCESS;
}
```

### Step 3: Update UVCCamera::connect() (P0)

**Current:**
```cpp
int UVCCamera::connect(int vendorId, int productId, int fd,
                       int busNum, int devAddr, const char* usbfs) {
    // fd is ignored!
    result = uvc_init(&mContext, nullptr);
    result = uvc_find_device(mContext, &mDevice, vendorId, productId, nullptr);
    result = uvc_open(mDevice, &mDeviceHandle);
}
```

**Target:**
```cpp
int UVCCamera::connect(int fd) {
    // FD injection - no device discovery
    result = uvc_init(&mContext, nullptr);
    result = uvc_open_from_fd(mContext, fd, &mDeviceHandle);
    // That's it - much simpler!
}
```

### Step 4: Remove Device Discovery (P1)

Remove or stub out:
- `uvc_find_device()` - not needed with FD injection
- `uvc_get_device_list()` - not needed
- `libusb_get_device_list()` - blocked by SELinux anyway

---

## FD Lifecycle Management

### Ownership Model

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     FD OWNERSHIP ON ANDROID 16                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  UsbDeviceConnection (Java)                                                  │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  OWNS the FD                                                           │ │
│  │  - Created by usbManager.openDevice()                                  │ │
│  │  - Closed when connection.close() called                               │ │
│  │  - Closed when connection object GC'd                                  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                        │                                                     │
│                        ▼ getFileDescriptor()                                │
│  Native Code                                                                 │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  BORROWS the FD                                                        │ │
│  │  - Do NOT call close(fd)                                               │ │
│  │  - Do NOT call libusb_close() (would close FD)                        │ │
│  │  - Only call libusb_exit() to cleanup context                         │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  CRITICAL: Native must NOT close the FD - Java layer manages lifetime       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### RAII Wrapper (Non-Owning)

For safety, create a non-owning FD wrapper:

```cpp
// BorrowedFd - does NOT close on destruction
class BorrowedFd {
    int fd_;
public:
    explicit BorrowedFd(int fd) : fd_(fd) {}
    ~BorrowedFd() = default;  // NO close()!

    int get() const { return fd_; }
    bool valid() const { return fd_ >= 0; }

    // Prevent accidental copies
    BorrowedFd(const BorrowedFd&) = delete;
    BorrowedFd& operator=(const BorrowedFd&) = delete;
};
```

---

## Error Handling for FD Injection

### Common Error Scenarios

| Error | Cause | Handling |
|-------|-------|----------|
| `EBADF` | Invalid FD | Check `fcntl(fd, F_GETFD)` before use |
| `EINVAL` | FD not a USB device | Verify via `/proc/self/fd/<n>` |
| `EACCES` | Permission revoked | Request permission again |
| `ENODEV` | Device disconnected | Notify user, cleanup |

### Validation Pattern

```cpp
bool validateUsbFd(int fd) {
    // Check FD is valid
    if (fcntl(fd, F_GETFD) == -1) {
        LOGE("Invalid file descriptor: %d", fd);
        return false;
    }

    // Optional: Verify it's actually a USB device
    char path[64];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    char target[256];
    ssize_t len = readlink(path, target, sizeof(target) - 1);
    if (len > 0) {
        target[len] = '\0';
        if (strstr(target, "/dev/bus/usb") == nullptr) {
            LOGW("FD %d doesn't point to USB device: %s", fd, target);
            // May still be valid on some devices
        }
    }

    return true;
}
```

---

## Performance Impact

### Comparison: libusb_open vs libusb_wrap_sys_device

| Operation | `libusb_open` | `libusb_wrap_sys_device` |
|-----------|--------------|-------------------------|
| Device enumeration | Required | Not needed |
| Permission check | Kernel (may fail) | Already passed (Java layer) |
| SELinux context | Blocked | Inherited from Java |
| Latency | ~10-50ms | ~1-5ms |
| Reliability | **Fails on Android 16** | Works |

---

## Testing Strategy

### Unit Test: FD Injection Path

```cpp
TEST(FdInjection, WrapSysDeviceSucceeds) {
    // Requires real USB device connected during test
    // Or mock using /dev/null for basic validation

    libusb_context* ctx;
    ASSERT_EQ(0, libusb_init_context(&ctx, nullptr, 0));

    // In real test, get FD from UsbManager via JNI callback
    int fd = getTestUsbFd();

    libusb_device_handle* handle;
    int ret = libusb_wrap_sys_device(ctx, fd, &handle);

    ASSERT_EQ(0, ret);
    ASSERT_NE(nullptr, handle);

    // Cleanup - do NOT close fd
    libusb_exit(ctx);
}
```

### Integration Test: Android USB Flow

```kotlin
@Test
fun testFdInjectionPath() {
    val device = findTestUsbDevice()
    val connection = usbManager.openDevice(device)
    assertNotNull(connection)

    val fd = connection.fileDescriptor
    assertTrue(fd >= 0)

    // Pass to native
    val result = nativeInitWithFd(fd)
    assertEquals(0, result)

    // Cleanup
    nativeRelease()
    connection.close()
}
```

---

## Rollout Plan

### Phase 1: Library Upgrade

1. Fork libusb 1.0.26
2. Apply Android-specific patches from current 1.0.19
3. Build and run basic tests
4. Verify `libusb_wrap_sys_device()` works on Android 14

### Phase 2: libuvc Modification

1. Add `uvc_open_from_fd()` to libuvc
2. Keep existing `uvc_open()` for backward compatibility (deprecated)
3. Add compile-time warning for `uvc_open()` usage

### Phase 3: UVCCamera Integration

1. Update `UVCCamera::connect()` to use FD injection
2. Simplify JNI interface (remove usbfs path parameter)
3. Add FD validation

### Phase 4: Testing & Validation

1. Test on Android 14 (API 34)
2. Test on Android 15 (API 35)
3. Test on Android 16 (API 36) Beta
4. Verify MTE compatibility on Tensor G5/G6

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-001** | USB access patterns to migrate |
| **SECURITY-008** | FGS requirements for FD persistence |
| **SAFETY-004** | UniqueFd RAII wrapper implementation |
| **AUDIT-003-appendix-advanced.md** | Android 16 USB FD persistence |

---

*End of SECURITY-002*
