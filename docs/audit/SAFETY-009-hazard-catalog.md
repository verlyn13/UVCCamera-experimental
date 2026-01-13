# SAFETY-009: Master Hazard Catalog

**Audit:** AUDIT-002 Memory Safety Audit
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

This catalog consolidates all memory safety hazards identified across SAFETY-001 through SAFETY-008. Hazards are classified by severity (P0-P3) and mapped to C++23 mitigation strategies.

| Priority | Count | Description |
|----------|-------|-------------|
| **P0** | 8 | Critical - Block Release |
| **P1** | 14 | High - Fix Before Migration |
| **P2** | 12 | Medium - Address During Migration |
| **P3** | 18 | Low - Opportunistic |

---

## Hazard Taxonomy

| Code | Category | C++23 Mitigation |
|------|----------|------------------|
| **MM** | Manual Memory | `std::unique_ptr`, `std::span` |
| **BO** | Buffer Overflow | `std::mdspan`, bounds checking |
| **PA** | Pointer Arithmetic | `std::span`, iterators |
| **RL** | Resource Leak | RAII wrappers |
| **EH** | Error Handling | `std::expected` |
| **JB** | JNI Boundary | RAII + validation |
| **HB** | Hardware Buffer | RAII wrappers |
| **SA** | Static Analysis | Fix identified issues |

---

## Priority 0: Critical (Block Release)

### P0-001: Double Free in FrameBufferJNI.cpp
- **Source:** SAFETY-008 (Static Analysis)
- **Location:** `FrameBufferJNI.cpp:129-130`
- **Category:** MM
- **Description:** Memory pointed to by 'ring' is freed twice
- **Migration:** Convert to `std::unique_ptr` with RAII

### P0-002: Use After Free in FrameBufferJNI.cpp
- **Source:** SAFETY-008 (Static Analysis)
- **Location:** `FrameBufferJNI.cpp:129`
- **Category:** MM
- **Description:** Dereferencing 'ring' after deallocation
- **Migration:** Convert to `std::unique_ptr`, use weak references

### P0-003: Integer Overflow in Frame Size Calculation
- **Source:** SAFETY-002 (Buffer Boundaries)
- **Location:** `UVCPreview.cpp:2469`
- **Category:** BO
- **Description:** `(y * width + x) * 4` can overflow int32
- **Migration:** Use `std::mdspan` with compile-time bounds

### P0-004: Unchecked Malloc in mCaptureBuffer
- **Source:** SAFETY-001 (Allocation Inventory)
- **Location:** `UVCPreview.cpp:2318`
- **Category:** MM
- **Description:** malloc return not checked before use
- **Migration:** `std::vector<std::byte>` with at() access

### P0-005: JNI Direct Buffer Lifetime
- **Source:** SAFETY-006 (JNI Boundaries)
- **Location:** `UVCPreview.cpp:1415`
- **Category:** JB
- **Description:** Native buffer may be freed while Java still using
- **Migration:** Use AHardwareBuffer shared across JNI

### P0-006: ANativeWindow Use After Surface Destroy
- **Source:** SAFETY-007 (Hardware Buffers)
- **Location:** `serenegiant_usb_UVCCamera.cpp:423`
- **Category:** HB
- **Description:** Surface may be destroyed while native holds reference
- **Migration:** Weak reference pattern, lifecycle callbacks

### P0-007: Missing Copy Constructor in PendingFrame
- **Source:** SAFETY-008 (Static Analysis)
- **Location:** `FrameBufferRing.h:78`
- **Category:** MM
- **Description:** Struct with raw pointer lacks Rule of Five
- **Migration:** Move-only with `std::unique_ptr<std::byte[]>`

### P0-008: pthread_create Without Error Check
- **Source:** SAFETY-004 (Resource Handles)
- **Location:** Multiple sites (60% coverage)
- **Category:** RL
- **Description:** Thread creation failure not handled
- **Migration:** `std::jthread` with RAII

---

## Priority 1: High (Fix Before Migration)

### P1-001: strdup Without Free Tracking
- **Source:** SAFETY-001
- **Location:** `UVCCamera.cpp` (mUsbFs)
- **Category:** MM
- **Migration:** `std::string`

### P1-002: malloc/free Pairing Imbalance
- **Source:** SAFETY-001
- **Location:** Multiple (162 malloc, 371 free)
- **Category:** MM
- **Migration:** `std::unique_ptr` or `std::vector`

### P1-003: Colorspace Conversion Without Bounds Check
- **Source:** SAFETY-002
- **Location:** `UVCPreview.cpp:2461-2570`
- **Category:** BO
- **Migration:** `std::mdspan` views

### P1-004: UV Plane Pointer Arithmetic
- **Source:** SAFETY-003
- **Location:** `UVCPreview.cpp:2465`
- **Category:** PA
- **Migration:** Separate `std::span` for each plane

### P1-005: I420 Cascading Plane Offsets
- **Source:** SAFETY-003
- **Location:** `UVCPreview.cpp:2532-2534`
- **Category:** PA
- **Migration:** I420Frame struct with validated spans

### P1-006: File Descriptor Leak Potential
- **Source:** SAFETY-004
- **Location:** 494 FD operations
- **Category:** RL
- **Migration:** `UniqueFd` RAII wrapper

### P1-007: libusb Handle Manual Management
- **Source:** SAFETY-004
- **Location:** 404 operations
- **Category:** RL
- **Migration:** `UniqueUsbHandle` wrapper

### P1-008: uvc_open Error Path Resource Leak
- **Source:** SAFETY-005
- **Location:** `UVCCamera.cpp`
- **Category:** EH
- **Migration:** `std::expected` with RAII

### P1-009: Return -1 Without Context
- **Source:** SAFETY-005
- **Location:** 138 sites
- **Category:** EH
- **Migration:** Typed error enums with `std::expected`

### P1-010: JNI String Null Check Missing
- **Source:** SAFETY-006
- **Location:** Multiple string operations
- **Category:** JB
- **Migration:** RAII JniString wrapper

### P1-011: Global Reference Lifecycle
- **Source:** SAFETY-006
- **Location:** 18 global refs
- **Category:** JB
- **Migration:** RAII JniGlobalRef wrapper

### P1-012: AHardwareBuffer Stride Mismatch
- **Source:** SAFETY-007
- **Location:** `FrameBufferRing.cpp:306`
- **Category:** HB
- **Migration:** Always use lockAndGetInfo on API 29+

### P1-013: Uninitialized Members in FrameBufferRing
- **Source:** SAFETY-008
- **Location:** `FrameBufferRing.cpp:109`
- **Category:** SA
- **Migration:** Initialize all members in constructor

### P1-014: Fence Timeout May Be Insufficient
- **Source:** SAFETY-007
- **Location:** `FrameBufferRing.cpp:260`
- **Category:** HB
- **Migration:** Increase to 32ms, add telemetry

---

## Priority 2: Medium (Address During Migration)

### P2-001: memcpy Without Size Validation
- **Source:** SAFETY-002
- **Location:** 154 sites in UVCCamera
- **Category:** BO
- **Migration:** `std::ranges::copy` with spans

### P2-002: sprintf Buffer Overflow Risk
- **Source:** SAFETY-002
- **Location:** 3 sites
- **Category:** BO
- **Migration:** `std::format` (C++20)

### P2-003: strcpy/strcat Usage
- **Source:** SAFETY-002
- **Location:** 10 unsafe string ops
- **Category:** BO
- **Migration:** `std::string` operations

### P2-004: Computed Index Without Bounds
- **Source:** SAFETY-003
- **Location:** ~100 sites
- **Category:** PA
- **Migration:** `std::span` with at()

### P2-005: Row Stride Copy Pattern
- **Source:** SAFETY-003
- **Location:** `UVCPreview.cpp:1103-1124`
- **Category:** PA
- **Migration:** `std::mdspan` row views

### P2-006: mmap Without Wrapper
- **Source:** SAFETY-004
- **Location:** 3 mmap regions
- **Category:** RL
- **Migration:** `MappedRegion` RAII class

### P2-007: Return NULL Loses Context
- **Source:** SAFETY-005
- **Location:** 103 sites
- **Category:** EH
- **Migration:** `std::expected<std::unique_ptr<T>, Error>`

### P2-008: Error Translation at Layers
- **Source:** SAFETY-005
- **Location:** JNI → UVC → libusb chain
- **Category:** EH
- **Migration:** Consistent error type hierarchy

### P2-009: Critical Array Access Timeout
- **Source:** SAFETY-006
- **Location:** turbojpeg-jni.c
- **Category:** JB
- **Migration:** Limit time in critical region

### P2-010: ANativeWindow Stride Assumption
- **Source:** SAFETY-007
- **Location:** `UVCPreview.cpp:359`
- **Category:** HB
- **Migration:** Always use `buffer.stride`

### P2-011: Reference Count Across JNI
- **Source:** SAFETY-007
- **Location:** `FrameBufferJNI.cpp`
- **Category:** HB
- **Migration:** Document ownership contract

### P2-012: objectarray.h Syntax Error
- **Source:** SAFETY-008
- **Location:** `objectarray.h:67`
- **Category:** SA
- **Migration:** Fix or remove unused code

---

## Priority 3: Low (Opportunistic)

### P3-001 through P3-018: Style and Modernization

| ID | Issue | Location | Migration |
|----|-------|----------|-----------|
| P3-001 | C-style casts | Multiple | `static_cast` etc. |
| P3-002 | NULL vs nullptr | Multiple | `nullptr` |
| P3-003 | Manual mutex | 100 ops | `std::mutex` |
| P3-004 | pthread_cond | 50 ops | `std::condition_variable` |
| P3-005 | Raw new/delete | 44/22 | `std::make_unique` |
| P3-006 | Magic numbers | Throughout | Named constants |
| P3-007 | Long functions | UVCPreview.cpp | Extract functions |
| P3-008 | Missing noexcept | Throughout | Add where applicable |
| P3-009 | Implicit conversions | Throughout | Explicit casts |
| P3-010 | Unused variables | Static analysis | Remove |
| P3-011 | Dead code | Throughout | Remove |
| P3-012 | Inconsistent naming | Throughout | Follow guidelines |
| P3-013 | Missing [[nodiscard]] | Return values | Add attribute |
| P3-014 | Implicit this capture | Lambdas | Explicit capture |
| P3-015 | std::endl vs '\\n' | Logging | Use '\\n' |
| P3-016 | Header guards vs pragma | Headers | Prefer pragma once |
| P3-017 | Trailing return types | Functions | Consider where clearer |
| P3-018 | Range-based for | Loops | Use where applicable |

---

## Migration Roadmap

### Phase 1: Critical Fixes (Weeks 1-2)
- P0-001 through P0-008
- Focus: Memory safety blockers
- Testing: AddressSanitizer enabled

### Phase 2: Core Infrastructure (Weeks 3-4)
- P1-001 through P1-014
- Focus: RAII wrappers, error handling
- Testing: Integration tests

### Phase 3: Buffer Safety (Weeks 5-6)
- P2-001 through P2-012
- Focus: std::span, std::mdspan adoption
- Testing: Fuzzing colorspace conversion

### Phase 4: Polish (Weeks 7-8)
- P3-001 through P3-018
- Focus: Code quality, modernization
- Testing: Full regression

---

## RAII Wrapper Summary

### Required Wrappers (Create in Phase 1)

```cpp
// Memory
using UniqueBytes = std::unique_ptr<std::byte[]>;
using UniqueBuffer = std::vector<std::byte>;

// File handles
class UniqueFd { int fd_ = -1; ... };

// USB/UVC handles
using UniqueUsbHandle = std::unique_ptr<libusb_device_handle, UsbDeleter>;
using UniqueUvcHandle = std::unique_ptr<uvc_device_handle_t, UvcDeleter>;

// Android platform
class UniqueHardwareBuffer { AHardwareBuffer* buffer_ = nullptr; ... };
class UniqueNativeWindow { ANativeWindow* window_ = nullptr; ... };

// JNI
class JniString { JNIEnv* env_; jstring str_; const char* utf_; ... };
class JniLocalRef<T> { JNIEnv* env_; T ref_; ... };
class JniGlobalRef<T> { JNIEnv* env_; T ref_; ... };

// Locks
class HardwareBufferLock { AHardwareBuffer* buffer_; void* ptr_; ... };
class NativeWindowLock { ANativeWindow* window_; ANativeWindow_Buffer buffer_; ... };
```

---

## Metrics

### Current State
| Metric | Count |
|--------|-------|
| Raw malloc | 162 |
| Raw free | 371 |
| Raw new | 44 |
| Raw delete | 22 |
| Unchecked returns | ~74% of malloc |
| pthread without check | 40% |
| Computed index | 580 |
| Pointer arithmetic | ~200 |

### Target State (Post-Migration)
| Metric | Target |
|--------|--------|
| Raw malloc | 0 (libjpeg-turbo excluded) |
| Raw free | 0 (libjpeg-turbo excluded) |
| Raw new | 0 |
| Raw delete | 0 |
| Unchecked returns | 0% |
| pthread | Replaced by std::jthread |
| Computed index | 0 (use std::mdspan) |
| Pointer arithmetic | 0 (use std::span) |

---

## Cross-Reference

### SAFETY Documents by Hazard Type

| Hazard ID | SAFETY Doc | Location |
|-----------|------------|----------|
| MM-* | SAFETY-001 | Allocation sites |
| BO-* | SAFETY-002 | Buffer boundaries |
| PA-* | SAFETY-003 | Pointer arithmetic |
| RL-* | SAFETY-004 | Resource handles |
| EH-* | SAFETY-005 | Error handling |
| JB-* | SAFETY-006 | JNI boundaries |
| HB-* | SAFETY-007 | Hardware buffers |
| SA-* | SAFETY-008 | Static analysis |

### Related Documentation

| Document | Relationship |
|----------|--------------|
| **AUDIT-001-appendix-background.md** | V4L2/UVC kernel context, Android 16 platform |
| **AUDIT-002-appendix-advanced.md** | Advanced std::mdspan patterns, V4L2 data_offset integration |
| **AUDIT-003-appendix-advanced.md** | Lock-free triple buffer (Appendix A), Android 16 USB (D), CVE-2024-58002 (E) |
| CONCURRENCY-002 | Sync primitives, atomic<shared_ptr> warning |
| CONCURRENCY-004 | Frame loop architecture using lock-free buffers |
| CONCURRENCY-010 | Master concurrency catalog (race conditions) |
| INVENTORY-006 | Baseline metrics, platform targets |

---

*End of SAFETY-009 - Master Hazard Catalog*
