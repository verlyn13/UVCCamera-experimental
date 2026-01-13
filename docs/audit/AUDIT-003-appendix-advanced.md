# AUDIT-003 Appendix: Advanced Concurrency Patterns

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Project:** ScopeCam - UVCCamera Library Modernization
**Target:** Android 16 (API 36) / C++20/23

---

## Overview

This appendix documents critical concurrency findings that affect the UVCCamera modernization strategy, including lock-free implementation requirements, Android 16 USB behavior, and CVE mitigations.

---

## Appendix A: Lock-Free Frame Buffer Implementation

### A.1 Critical Correction: std::atomic<std::shared_ptr> is NOT Lock-Free

**Research Finding:** The libc++ implementation of `std::atomic<std::shared_ptr>` uses a **global mutex pool** (mutex striping), NOT hardware atomics.

**What Actually Happens:**
```cpp
// This looks lock-free but ISN'T in libc++
std::atomic<std::shared_ptr<FrameBuffer>> current_frame;

// Internal implementation:
// 1. Hash address of current_frame -> bucket index
// 2. Acquire global mutex from pool[bucket]
// 3. Perform non-atomic update
// 4. Release mutex
// If another shared_ptr hashes to same bucket -> BLOCKED
```

**Why libc++ Cannot Use True Lock-Free:**
- 128-bit atomics (LDXP/STXP) require 16-byte alignment
- `std::shared_ptr` is only 8-byte aligned
- Changing alignment would break ABI compatibility
- Google/LLVM prioritize ABI stability over performance

### A.2 Correct Implementation: Lock-Free Triple Buffer

```cpp
// TRUE lock-free triple buffer for frame delivery
class LockFreeFrameBuffer {
    alignas(64) std::array<FrameBuffer, 3> buffers_;  // Cache-line aligned
    alignas(64) std::atomic<uint32_t> write_idx_{0};  // Separate cache line
    alignas(64) std::atomic<uint32_t> read_idx_{1};   // Separate cache line

public:
    // Producer (capture thread) - wait-free, never blocks
    FrameBuffer& get_write_buffer() noexcept {
        return buffers_[write_idx_.load(std::memory_order_relaxed)];
    }

    void publish() noexcept {
        uint32_t current = write_idx_.load(std::memory_order_relaxed);
        uint32_t next = (current + 1) % 3;

        // Skip buffer being read
        if (next == read_idx_.load(std::memory_order_acquire)) {
            next = (next + 1) % 3;
        }
        write_idx_.store(next, std::memory_order_release);
    }

    // Consumer (render/JNI thread) - wait-free, never blocks capture
    const FrameBuffer* get_read_buffer() noexcept {
        uint32_t latest = write_idx_.load(std::memory_order_acquire);
        uint32_t current = read_idx_.load(std::memory_order_relaxed);

        if (latest == current) return nullptr;  // No new frame

        read_idx_.store(latest, std::memory_order_release);
        return &buffers_[latest];
    }
};
```

### A.3 Performance Comparison

| Metric | libc++ atomic<shared_ptr> | Lock-Free Triple Buffer |
|--------|--------------------------|------------------------|
| Progress Guarantee | **Blocking** | **Wait-Free** |
| Latency Profile | High variance (mutex) | Deterministic |
| Cache Behavior | Thrashing (mutex + control block) | Optimized (padding) |
| Contention | Global (affects unrelated ptrs) | Local (producer/consumer only) |
| Reference Counting | Yes (RMW per access) | No (ownership by slot) |

### A.4 Migration Recommendations

| Priority | Action |
|----------|--------|
| **P0** | Replace mutex-guarded frame buffers with lock-free ring/triple buffers |
| **P1** | Do NOT use `std::atomic<std::shared_ptr>` in hot paths |
| **P2** | For shared ownership needs, use raw pointers in ring buffer + deferred reclamation |

---

## Appendix D: Android 16 USB File Descriptor Persistence

### D.1 Advanced Data Protection and Session Continuity

Android 16 introduces hardware-level USB data pin control under "Advanced Data Protection." This has critical implications for ScopeCam's concurrency model.

**Key Finding:** Established USB sessions persist across lock events.

| User Action | USB Protection Status | NDK File Descriptor |
|-------------|----------------------|---------------------|
| Connect (unlocked) -> Lock | Active | **Persists** (read/write OK) |
| Connect while locked | Blocked | **None** (cannot create) |
| Disconnect while locked -> Reconnect | Blocked | **Must unlock + re-plug** |

### D.2 Foreground Service Dependency

The FD persistence is conditional on app lifecycle management.

**Without proper Foreground Service configuration:**
1. Screen locks -> Doze mode -> App classified as "cached"
2. System kills process to save battery
3. Kernel closes all FDs owned by process
4. USB connection severed

**Required Configuration:**
```xml
<manifest>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>

    <service
        android:name=".UsbCameraService"
        android:foregroundServiceType="connectedDevice"
        android:exported="false"/>
</manifest>
```

**Audit Action:** Verify ScopeCam implements `connectedDevice` foreground service type.

### D.3 Error Handling for USB Protection

NDK code must distinguish between:
- **Physical disconnect:** `ENODEV` from read/write
- **Policy disconnect:** Same error, but cannot reconnect while locked

**Recommended Pattern:**
```cpp
ssize_t bytes = read(usb_fd, buffer, size);
if (bytes < 0) {
    if (errno == ENODEV || errno == EIO) {
        // Check if device is locked (via JNI callback)
        if (is_device_locked()) {
            notify_user("Unlock device and re-plug USB to reconnect");
        } else {
            notify_user("USB device disconnected");
        }
        // Do NOT busy-wait for USB_DEVICE_ATTACHED
    }
}
```

---

## Appendix E: CVE-2024-58002 and UVC Async Control Hazards

### E.1 The Vulnerability

A critical kernel vulnerability affects UVC async control handling - directly relevant to ScopeCam's long-exposure use case.

**The Bug:**
1. App initiates async control (e.g., "Start 30s Exposure")
2. App crashes or times out waiting
3. File handle closes, but kernel holds reference for pending interrupt
4. Device finishes exposure, sends status interrupt
5. `uvc_ctrl_status_event` dereferences freed file handle pointer
6. **Kernel panic / Use-After-Free**

**Attack Timeline:**
```
Userspace                          Kernel (uvcvideo)
    |                                   |
    |  SET_CUR(Exposure=30s)            |
    |  ------------------------------>  |
    |                                   |  Wait for status interrupt
    |  [Timeout after 5s]               |      |
    |      |                            |      |
    |  close(fd)                        |      |
    |      |                            |      |
    |      v                            |      |
    |  App crashes/exits                |      |
    |                                   |      |  (25s later...)
    |                                   |      |
    |                                   |  Device sends "Control Complete"
    |                                   |      |
    |                                   |  uvc_ctrl_status_event(stale_fh)
    |                                   |      |
    |                                   |  USE-AFTER-FREE / PANIC
```

### E.2 Mitigation Status

**Patches by Ricardo Ribalda (2024-2025):**
- Sanitize file handle pointers before dereference
- Use separate async worker thread with proper synchronization
- Backported to kernel 5.15+

**ScopeCam Audit Actions:**
1. Check target kernel version (must be patched 5.15+ or 6.1+)
2. Document any async control patterns in libuvc
3. Consider implementing synchronous-only mode for safety

### E.3 UVC Quirk Flags for Long Exposure

Scientific sensors require specific kernel configuration:

```bash
# /etc/modprobe.d/uvc-industrial.conf
options uvcvideo quirks=33408 timeout=60000 nodrop=1
```

**Breakdown:**

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `quirks` | 33408 (0x8280) | FIX_BANDWIDTH + RESTRICT_FRAME_RATE + DISABLE_AUTOSUSPEND |
| `timeout` | 60000ms | Support 60s exposures without timeout |
| `nodrop` | 1 | Don't drop frames with minor header errors |

**Critical Quirks for Industrial Cameras:**
- `UVC_QUIRK_DISABLE_AUTOSUSPEND` (0x8000): Prevents kernel from suspending "idle" device during long exposure
- `UVC_QUIRK_STATUS_INTERVAL` (0x01): Fixes async control completion interrupt polling

---

## Appendix F: Corrected Migration Priority Matrix

### F.1 Revised Quick Wins

| Item | Original Assessment | Revised | Rationale |
|------|--------------------| --------|-----------|
| `volatile bool` -> `std::atomic<bool>` | Quick Win | **Quick Win** | Still correct |
| `pthread_mutex` -> `std::atomic<shared_ptr>` | Medium | **AVOID** | libc++ is blocking |
| `pthread_mutex` -> Lock-free ring buffer | Major | **P0 Priority** | True lock-freedom |
| Add `poll()` timeout before `ioctl` | Quick Win | **Quick Win** | Still correct |

### F.2 Updated Implementation Dependencies

```
Foundation (Implement First)
├── std::jthread Migration
├── stop_token Integration
└── Lock-Free Ring Buffer (NOT atomic<shared_ptr>!)

DO NOT USE
└── std::atomic<shared_ptr> (blocking in libc++)

Async Infrastructure
├── Async Event Loop
└── Coroutine Wrappers

Integration
├── Kotlin Flow Bridge
└── HardwareBuffer Path
```

### F.3 Key Takeaway

**The "modern C++" path is not always the performant path.** `std::atomic<std::shared_ptr>` looks elegant but performs worse than hand-rolled solutions due to ABI constraints in libc++. For ScopeCam's 60fps frame delivery, true lock-freedom via triple buffers or SPSC ring queues is mandatory.

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **AUDIT-001-appendix-background.md** | UVC quirk flags (C.2), CVE-2024-58002 (C.3), Android 16 USB (D.2) |
| **CONCURRENCY-002** | Sync primitives - add atomic<shared_ptr> warning |
| **CONCURRENCY-004** | Frame loop architecture using lock-free buffers |
| **CONCURRENCY-009** | Coroutine feasibility - revised priorities |
| **CONCURRENCY-010** | Master catalog with updated hazards |

---

*End of AUDIT-003 Appendix*
