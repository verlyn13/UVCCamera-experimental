# SAFETY-005: Error Handling Pattern Analysis

**Audit:** AUDIT-002 Memory Safety Audit
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Summary Statistics

| Pattern | Count |
|---------|-------|
| **return -1** | 138 |
| **return NULL/nullptr** | 103 |
| **UVC/LIBUSB error codes** | 1729 references |
| **Error checking (if < 0)** | ~200 |

---

## Error Code Systems

### UVC Error Codes (libuvc)

```c
typedef enum uvc_error {
    UVC_SUCCESS = 0,
    UVC_ERROR_IO = -1,
    UVC_ERROR_INVALID_PARAM = -2,
    UVC_ERROR_ACCESS = -3,
    UVC_ERROR_NO_DEVICE = -4,
    UVC_ERROR_NOT_FOUND = -5,
    UVC_ERROR_BUSY = -6,
    UVC_ERROR_TIMEOUT = -7,
    UVC_ERROR_OVERFLOW = -8,
    UVC_ERROR_PIPE = -9,
    UVC_ERROR_INTERRUPTED = -10,
    UVC_ERROR_NO_MEM = -11,
    UVC_ERROR_NOT_SUPPORTED = -12,
    UVC_ERROR_INVALID_DEVICE = -50,
    UVC_ERROR_INVALID_MODE = -51,
    UVC_ERROR_CALLBACK_EXISTS = -52,
    UVC_ERROR_OTHER = -99
} uvc_error_t;
```

### LIBUSB Error Codes

```c
enum libusb_error {
    LIBUSB_SUCCESS = 0,
    LIBUSB_ERROR_IO = -1,
    LIBUSB_ERROR_INVALID_PARAM = -2,
    LIBUSB_ERROR_ACCESS = -3,
    // ... similar to UVC
};
```

---

## Critical Error Handling Patterns

### EH-001: Unchecked UVC Open (UVCCamera.cpp)

**Location:** `UVCCamera/UVCCamera.cpp`
**Pattern:**
```cpp
result = uvc_open(mDevice, &mDeviceHandle);
if (UNLIKELY(result)) {
    LOGE("uvc_open failed: %d", result);
    // Error returned but not all resources cleaned up
}
```

**Risk:** Partial resource cleanup on failure
**2026 Migration:**
```cpp
auto result = uvc_open(mDevice);
if (!result) {
    return std::unexpected(UvcError::from(result.error()));
}
auto handle = std::move(*result);  // RAII handle
```

---

### EH-002: Silent Failure in Frame Callback

**Location:** `UVCCamera/UVCPreview.cpp` (frame_callback)
**Pattern:**
```cpp
if (frame->data_bytes == 0) {
    LOGW("Empty frame received");
    return;  // Silent failure
}
```

**Risk:** Caller has no indication of failure
**2026 Migration:** Use telemetry counters (already implemented)

---

### EH-003: Return -1 Patterns

**Locations:** Throughout codebase (138 sites)
**Pattern:**
```c
int some_function(...) {
    if (error_condition) {
        return -1;  // Generic failure
    }
    return 0;
}
```

**Issues:**
1. No error context
2. Caller may not check
3. -1 indistinguishable from other errors

**2026 Migration:**
```cpp
enum class FunctionError { InvalidParam, NoMemory, DeviceBusy, IoError };

std::expected<ReturnType, FunctionError> some_function(...) {
    if (error_condition) {
        return std::unexpected(FunctionError::InvalidParam);
    }
    return value;
}
```

---

### EH-004: Return NULL Patterns

**Locations:** 103 sites
**Pattern:**
```c
device_t* get_device() {
    device_t* dev = malloc(sizeof(*dev));
    if (!dev) return NULL;
    // ...
    if (error) {
        free(dev);
        return NULL;  // Loses error context
    }
    return dev;
}
```

**2026 Migration:**
```cpp
std::expected<std::unique_ptr<device_t>, DeviceError> get_device() {
    auto dev = std::make_unique<device_t>();
    // ...
    if (error) {
        return std::unexpected(DeviceError::InitFailed);
    }
    return dev;
}
```

---

## Error Propagation Analysis

### UVCCamera.cpp Error Flow

```
Java (UVCCamera.java)
  ↓ JNI call
nativeConnect(...)
  ↓
UVCCamera::connect()
  ↓ returns int (0 or error code)
uvc_open()
  ↓ returns uvc_error_t
libusb_open()
  ↓ returns int
```

**Issues:**
1. Error codes translated at each layer
2. Context lost in translation
3. Java receives generic error code

---

### Error Check Coverage

| Function | Call Sites | Checked | % Checked |
|----------|------------|---------|-----------|
| `uvc_open()` | 5 | 5 | 100% |
| `uvc_stream_start()` | 3 | 3 | 100% |
| `malloc()` | 162 | ~120 | ~74% |
| `pthread_create()` | 5 | 3 | 60% |

---

## std::expected Migration Plan

### Error Type Hierarchy

```cpp
// Base error type
enum class BaseError {
    OutOfMemory,
    InvalidParameter,
    IoError,
    Timeout
};

// Device-specific errors
enum class DeviceError {
    NotFound,
    AccessDenied,
    Busy,
    Disconnected,
    InvalidState
};

// Stream-specific errors
enum class StreamError {
    NotStarted,
    AlreadyRunning,
    FormatNotSupported,
    BufferOverflow
};

// Composite error using std::variant
using UvcError = std::variant<BaseError, DeviceError, StreamError>;
```

### Migration Example

**Before:**
```cpp
int UVCCamera::connect(int vid, int pid, int fd, int busNum, int devAddr, const char* usbfs) {
    // ... setup ...
    int result = uvc_init(&mContext, NULL);
    if (result < 0) {
        LOGE("uvc_init failed: %d", result);
        return result;
    }
    // ... more operations that can fail ...
    return 0;
}
```

**After:**
```cpp
std::expected<void, UvcError> UVCCamera::connect(
    DeviceDescriptor desc,
    std::string_view usbfs
) {
    auto ctx = uvc_init();
    if (!ctx) {
        return std::unexpected(ctx.error());
    }
    mContext = std::move(*ctx);

    auto device = uvc_find_device(mContext, desc);
    if (!device) {
        return std::unexpected(device.error());
    }
    mDevice = std::move(*device);

    auto handle = uvc_open(mDevice);
    if (!handle) {
        return std::unexpected(handle.error());
    }
    mDeviceHandle = std::move(*handle);

    return {};  // Success
}
```

---

## Error Logging Patterns

### Current (LOGX macros)
```cpp
LOGE("Error: %s at %s:%d", message, __FILE__, __LINE__);
```

### 2026 Enhancement
```cpp
// Structured error with context
struct ErrorContext {
    std::string_view function;
    std::source_location location;
    std::chrono::system_clock::time_point timestamp;
    std::optional<int> errno_value;
};

// Error result carries context
template<typename E>
struct ErrorWithContext {
    E error;
    ErrorContext context;
};
```

---

## Priority Fixes

### Phase 1: Critical Path
1. `uvc_open` → `std::expected`
2. `uvc_stream_start` → `std::expected`
3. Device lifecycle functions

### Phase 2: Important
1. All `malloc`/allocation returns → checked
2. pthread operations → `std::jthread`
3. JNI boundary error propagation

### Phase 3: Complete Coverage
1. All return -1 → `std::expected`
2. All return NULL → `std::expected`

---

*End of SAFETY-005*
