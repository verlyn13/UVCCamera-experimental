# SAFETY-004: Resource Handle Audit

**Audit:** AUDIT-002 Memory Safety Audit
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Summary Statistics

| Resource Type | Operations | Declarations |
|---------------|------------|--------------|
| **File Descriptors** | 494 | 113 |
| **libusb handles** | 404 | N/A |
| **UVC handles** | 256 | N/A |
| **Thread handles** | 267 | N/A |
| **mmap regions** | 3 | N/A |

---

## File Descriptor Resources

### RL-001: USB Device FD (UVCCamera Core)

**Acquisition:** Device open via libusb
**Release:** `libusb_close()` → `close(fd)`

**Current Pattern:**
```cpp
// In libusb/os/android_usbfs.c
int fd = open(device_path, O_RDWR);
// ... used throughout device lifetime
close(fd);
```

**RAII Wrapper:**
```cpp
class UniqueFd {
    int fd_ = -1;
public:
    UniqueFd() = default;
    explicit UniqueFd(int fd) noexcept : fd_(fd) {}
    ~UniqueFd() { if (fd_ >= 0) ::close(fd_); }

    UniqueFd(UniqueFd&& o) noexcept : fd_(std::exchange(o.fd_, -1)) {}
    UniqueFd& operator=(UniqueFd&& o) noexcept {
        reset();
        fd_ = std::exchange(o.fd_, -1);
        return *this;
    }

    [[nodiscard]] int get() const noexcept { return fd_; }
    [[nodiscard]] int release() noexcept { return std::exchange(fd_, -1); }
    void reset(int fd = -1) noexcept {
        if (fd_ >= 0) ::close(fd_);
        fd_ = fd;
    }
    explicit operator bool() const noexcept { return fd_ >= 0; }
};
```

---

### RL-002: Capture FD (UVCPreview)

**Location:** `UVCCamera/UVCPreview.cpp` (captureToFd)
**Pattern:** FD passed in from Java, not owned by native code

**Risk:** FD may be closed by Java while native still using
**Mitigation:** Document ownership contract clearly

---

## USB Handle Resources

### RL-100: libusb_device_handle

**Acquisition:** `libusb_open()`
**Release:** `libusb_close()`

**Current Pattern (libuvc/src/device.c):**
```c
uvc_error_t ret = libusb_open(dev->usb_dev, &devh->usb_devh);
// ...
libusb_close(devh->usb_devh);
```

**RAII Wrapper:**
```cpp
using UniqueUsbHandle = std::unique_ptr<
    libusb_device_handle,
    decltype([](libusb_device_handle* h) { if (h) libusb_close(h); })
>;
```

---

### RL-101: libusb_context

**Acquisition:** `libusb_init()`
**Release:** `libusb_exit()`

**RAII Wrapper:**
```cpp
using UniqueUsbContext = std::unique_ptr<
    libusb_context,
    decltype([](libusb_context* ctx) { if (ctx) libusb_exit(ctx); })
>;
```

---

## UVC Handle Resources

### RL-200: uvc_device_handle_t

**Acquisition:** `uvc_open()`
**Release:** `uvc_close()`

**Lifecycle in UVCCamera:**
```cpp
// UVCCamera.cpp connect()
result = uvc_open(mDevice, &mDeviceHandle);
// ...
// UVCCamera.cpp disconnect()
uvc_close(mDeviceHandle);
```

**RAII Wrapper:**
```cpp
using UniqueUvcHandle = std::unique_ptr<
    uvc_device_handle,
    decltype([](uvc_device_handle_t* h) { if (h) uvc_close(h); })
>;
```

---

### RL-201: uvc_stream_handle_t

**Acquisition:** `uvc_stream_open_ctrl()`
**Release:** `uvc_stream_close()`

**Critical Resource:** Manages USB streaming endpoint

---

## Thread Handle Resources

### RL-300: pthread_t (Preview Thread)

**Location:** `UVCCamera/UVCPreview.cpp`
**Current Pattern:**
```cpp
pthread_t preview_thread;
pthread_create(&preview_thread, NULL, preview_thread_func, this);
// ...
pthread_join(preview_thread, NULL);
```

**2026 Migration:**
```cpp
std::jthread preview_thread{[this](std::stop_token token) {
    preview_thread_func(token);
}};
// Automatic join on destruction, cooperative cancellation
```

---

### RL-301: pthread_mutex_t / pthread_cond_t

**Locations:** Throughout codebase
**Count:** ~100 mutex operations, ~50 condition variable operations

**2026 Migration:**
```cpp
std::mutex mtx;
std::condition_variable cv;
// Or std::condition_variable_any for stop_token support
```

---

## Memory Mapping Resources

### RL-400: mmap Regions

**Locations:** `libusb/libusb/os/android_usbfs.c`
**Count:** 3 mmap/munmap pairs

**Pattern:**
```c
void* ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
// ...
munmap(ptr, size);
```

**RAII Wrapper:**
```cpp
class MappedRegion {
    void* ptr_ = MAP_FAILED;
    size_t size_ = 0;
public:
    MappedRegion() = default;
    MappedRegion(void* ptr, size_t size) noexcept : ptr_(ptr), size_(size) {}
    ~MappedRegion() { if (ptr_ != MAP_FAILED) munmap(ptr_, size_); }

    // Move-only semantics...

    [[nodiscard]] void* get() const noexcept { return ptr_; }
    [[nodiscard]] size_t size() const noexcept { return size_; }
    explicit operator bool() const noexcept { return ptr_ != MAP_FAILED; }
};
```

---

## AHardwareBuffer Resources

### RL-500: AHardwareBuffer (FrameBufferRing)

**Location:** `UVCCamera/FrameBufferRing.cpp`
**Acquisition:** `AHardwareBuffer_allocate()`
**Release:** `AHardwareBuffer_release()`

**Current Pattern:**
```cpp
AHardwareBuffer* buffer = nullptr;
AHardwareBuffer_allocate(&desc, &buffer);
// ...
AHardwareBuffer_release(buffer);
```

**RAII Wrapper:**
```cpp
using UniqueHardwareBuffer = std::unique_ptr<
    AHardwareBuffer,
    decltype([](AHardwareBuffer* b) { if (b) AHardwareBuffer_release(b); })
>;
```

---

## Resource Lifecycle Summary

| Resource | Acquire | Release | Error Path Coverage | RAII Priority |
|----------|---------|---------|---------------------|---------------|
| USB FD | `open()` | `close()` | Partial | High |
| libusb handle | `libusb_open()` | `libusb_close()` | Good | Medium |
| UVC handle | `uvc_open()` | `uvc_close()` | Good | Medium |
| Stream handle | `uvc_stream_open_ctrl()` | `uvc_stream_close()` | Partial | High |
| pthread | `pthread_create()` | `pthread_join()` | Partial | High |
| mmap | `mmap()` | `munmap()` | Good | Low |
| AHardwareBuffer | `allocate()` | `release()` | Good | Medium |

---

## Migration Priority

### Phase 1 (Immediate)
1. `UniqueFd` for all file descriptors
2. `std::jthread` for all threads

### Phase 2 (Near-term)
1. USB handle wrappers
2. UVC handle wrappers
3. AHardwareBuffer wrapper

### Phase 3 (Long-term)
1. Mutex/condition variable modernization
2. mmap wrapper (if needed)

---

*End of SAFETY-004*
