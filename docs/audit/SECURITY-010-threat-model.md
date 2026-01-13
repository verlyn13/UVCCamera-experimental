# SECURITY-010: Security Threat Model

**Audit:** AUDIT-004 Android Security Compliance
**Generated:** 2026-01-11
**Target:** UVCCamera Library

---

## Executive Summary

This document provides a comprehensive security threat model for the UVCCamera library, identifying attack vectors, trust boundaries, and mitigations.

---

## Attack Surface Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ATTACK SURFACE MODEL                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  EXTERNAL INPUTS (Untrusted)                                                 │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  1. USB Device Data        → Validate in libuvc/libusb                 │ │
│  │  2. Java Handle IDs        → Lookup in HandleManager (never cast)      │ │
│  │  3. File URIs from SAF     → Framework validates, native receives FD   │ │
│  │  4. Camera parameters      → Bounds check before applying              │ │
│  │  5. Frame dimensions       → Validate against device capabilities      │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  TRUST BOUNDARIES                                                            │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                                                                        │ │
│  │  [Java/Kotlin]  ═══════ JNI ═══════  [Native C++]                     │ │
│  │       │                                     │                          │ │
│  │       │   ✓ Handle IDs (opaque integers)   │                          │ │
│  │       │   ✓ File Descriptors               │                          │ │
│  │       │   ✓ Primitive values (bounds checked)                         │ │
│  │       │                                     │                          │ │
│  │       │   ✗ Raw pointers                   │                          │ │
│  │       │   ✗ File paths (blocked by Scoped Storage)                    │ │
│  │       │   ✗ Device names/paths             │                          │ │
│  │                                                                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  INTERNAL COMPONENTS                                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                                                                        │ │
│  │  HandleManager        → Slot-based, generation-validated handles      │ │
│  │  FrameBufferRing      → AHardwareBuffer-backed ring buffer           │ │
│  │  UVCCamera            → USB video class control                       │ │
│  │  libuvc               → UVC protocol implementation                   │ │
│  │  libusb               → USB communication                             │ │
│  │                                                                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Threat Categories

### T1: Stale Handle Exploitation

| Attribute | Value |
|-----------|-------|
| **Vector** | Attacker passes invalid/freed handle ID |
| **Impact** | Potential use-after-free, crash, or code execution |
| **Likelihood** | MEDIUM (requires app compromise or race condition) |
| **Mitigation** | HandleManager lookup with generation validation |
| **Status** | ✅ MITIGATED |

**Attack Scenario:**
1. Attacker obtains valid handle ID (e.g., via logging)
2. Waits for object to be freed
3. Triggers reallocation to reuse memory
4. Passes stale handle to JNI function
5. Native code dereferences corrupted memory

**Defense:**
```cpp
auto ref = handleManager.acquire(handle);
if (!ref) {
    // Generation mismatch - handle invalid
    throw IllegalStateException("Invalid handle");
}
// ref.ptr is guaranteed valid for scope lifetime
```

---

### T2: 32-bit Truncation

| Attribute | Value |
|-----------|-------|
| **Vector** | Large jlong value on ILP32 architecture |
| **Impact** | Wrong memory access, crash |
| **Likelihood** | LOW (ARM64 is dominant) |
| **Mitigation** | HandleManager (ID is never a pointer) |
| **Status** | ✅ MITIGATED |

**Attack Scenario:**
```cpp
// On 32-bit ARM
jlong handle = 0x00000001_FFFFFFFF;  // >4GB
void* ptr = (void*)(intptr_t)handle; // TRUNCATION
// ptr = 0xFFFFFFFF (wrong address)
```

**Defense:** HandleManager stores opaque integer IDs, not pointers.

---

### T3: MTE Bypass Attempt

| Attribute | Value |
|-----------|-------|
| **Vector** | Integer-to-pointer cast to evade tagging |
| **Impact** | Memory corruption, code execution |
| **Likelihood** | MEDIUM (requires native code modification) |
| **Mitigation** | Clang-Tidy enforcement blocks pattern |
| **Status** | ✅ MITIGATED |

**Attack Scenario:**
```cpp
// Attacker modifies JNI function:
void* ptr = (void*)(intptr_t)attacker_value;  // No MTE tag
*ptr = malicious_payload;  // Memory corruption
```

**Defense:** Clang-Tidy custom check `jni-no-raw-pointer-cast` blocks this pattern at build time.

---

### T4: USB Privilege Escalation

| Attribute | Value |
|-----------|-------|
| **Vector** | Native code opens arbitrary USB devices |
| **Impact** | Access to unauthorized peripherals |
| **Likelihood** | HIGH (on pre-Android 16) |
| **Mitigation** | FD injection (framework controls access) |
| **Status** | ⚠️ REQUIRES MIGRATION |

**Attack Scenario:**
```cpp
// Attacker-controlled code in native library:
libusb_open_device_with_vid_pid(ctx, 0x1234, 0x5678);
// Opens any USB device without permission dialog
```

**Defense (Post-Migration):**
- Native code receives FD from framework
- Framework enforces UsbManager.requestPermission()
- SELinux blocks direct `/dev/bus/usb` access

---

### T5: Storage Path Traversal

| Attribute | Value |
|-----------|-------|
| **Vector** | Native code writes outside app sandbox |
| **Impact** | Data theft, malware installation |
| **Likelihood** | LOW (Scoped Storage enforced) |
| **Mitigation** | FD injection, no raw path access |
| **Status** | ✅ COMPLIANT |

**Attack Scenario:**
```cpp
// Attempt to write to system location:
fopen("/data/system/packages.xml", "w");  // BLOCKED
fopen("/sdcard/Download/payload.apk", "w");  // BLOCKED
```

**Defense:** Scoped Storage blocks all raw path access. Native receives FDs from framework.

---

### T6: Session Hijacking

| Attribute | Value |
|-----------|-------|
| **Vector** | Background service steals USB session |
| **Impact** | Unauthorized camera access |
| **Likelihood** | LOW (Android 16 ADP) |
| **Mitigation** | ADP hardware lockout when screen locks |
| **Status** | ✅ MITIGATED by platform |

**Attack Scenario:**
1. Malicious background service monitors for USB connections
2. Attempts to open device while legitimate app is paused
3. Hijacks camera session

**Defense:** Advanced Data Protection physically disables USB data pins when screen is locked. New connections require unlock + re-plug.

---

### T7: Use-After-Free in JNI

| Attribute | Value |
|-----------|-------|
| **Vector** | Race condition between destroy and use |
| **Impact** | Crash, potential code execution |
| **Likelihood** | MEDIUM (concurrent access) |
| **Mitigation** | HandleManager activeRefs draining |
| **Status** | ✅ MITIGATED |

**Attack Scenario:**
```
Thread A: validateHandle(id) → returns ptr
Thread B: destroyCamera() → deletes object
Thread A: Uses dangling ptr → CRASH
```

**Defense:**
```cpp
// HandleManager::acquire() increments activeRefs BEFORE validation
// HandleManager::invalidateAndFree() waits for activeRefs == 0
```

---

### T8: Buffer Overflow in Frame Processing

| Attribute | Value |
|-----------|-------|
| **Vector** | Malformed frame data from USB device |
| **Impact** | Memory corruption, crash |
| **Likelihood** | MEDIUM (requires malicious device) |
| **Mitigation** | Bounds checking, std::span migration |
| **Status** | ⚠️ PARTIAL (see SAFETY-002) |

**Attack Scenario:**
1. Malicious USB device sends oversized frame
2. `memcpy(dst, src, claimed_size)` overflows buffer
3. Memory corruption

**Defense (Planned):**
- Validate frame size against allocated buffer
- Use `std::mdspan` for bounds-checked access
- See SAFETY-002 for colorspace conversion hardening

---

### T9: Integer Overflow in Size Calculation

| Attribute | Value |
|-----------|-------|
| **Vector** | Large width/height causing overflow |
| **Impact** | Under-allocated buffer, corruption |
| **Likelihood** | LOW (requires malicious input) |
| **Mitigation** | Safe integer arithmetic |
| **Status** | ⚠️ PARTIAL (see SAFETY-002) |

**Attack Scenario:**
```cpp
// width = 65536, height = 65536
int size = width * height * 4;  // OVERFLOW on 32-bit int
uint8_t* buf = malloc(size);    // Under-allocated
memcpy(buf, data, actual_size); // Overflow
```

**Defense (Planned):**
```cpp
size_t size;
if (__builtin_mul_overflow(width, height, &size) ||
    __builtin_mul_overflow(size, 4, &size)) {
    return std::unexpected(BufferError::Overflow);
}
```

---

## Trust Boundary Analysis

### JNI Boundary (Critical)

| Input Type | Validation Required |
|------------|---------------------|
| `jlong handle` | HandleManager lookup |
| `jint fd` | fcntl(F_GETFD) check |
| `jint param` | Range validation |
| `jintArray` | Length check before access |
| `jbyteArray` | Length check, critical region limit |
| `jstring` | Null check, UTF conversion |
| `jobject` | Null check, type verification |

### USB Boundary

| Data Type | Validation |
|-----------|------------|
| Frame data | Size vs descriptor, format validation |
| Control responses | Expected length, status check |
| Descriptors | Parse carefully, handle malformed |
| Interrupt data | Timeout handling, async safety |

---

## Security Controls Matrix

| Control | Implementation | Coverage |
|---------|----------------|----------|
| Handle/Map Pattern | HandleManager.h | ✅ Complete |
| MTE Tag Preservation | uintptr_t storage | ✅ Complete |
| Generation Validation | Slot-based IDs | ✅ Complete |
| Reference Counting | ScopedRef RAII | ✅ Complete |
| FD Injection | Planned | ⚠️ Pending |
| Bounds Checking | Partial | ⚠️ In progress |
| Integer Overflow | Planned | ⚠️ Pending |
| Clang-Tidy Enforcement | Configured | ✅ Ready |

---

## Risk Matrix

| Threat | Likelihood | Impact | Risk Score | Status |
|--------|------------|--------|------------|--------|
| T1: Stale Handle | Medium | High | **HIGH** | ✅ Mitigated |
| T2: 32-bit Truncation | Low | High | **MEDIUM** | ✅ Mitigated |
| T3: MTE Bypass | Medium | Critical | **HIGH** | ✅ Mitigated |
| T4: USB Privilege | High | High | **CRITICAL** | ⚠️ Needs work |
| T5: Path Traversal | Low | High | **MEDIUM** | ✅ Compliant |
| T6: Session Hijack | Low | Medium | **LOW** | ✅ Platform |
| T7: Use-After-Free | Medium | Critical | **HIGH** | ✅ Mitigated |
| T8: Buffer Overflow | Medium | High | **HIGH** | ⚠️ Partial |
| T9: Integer Overflow | Low | High | **MEDIUM** | ⚠️ Pending |

---

## Recommendations

### Immediate (P0)

1. **Complete FD injection migration** - Remove direct `libusb_open()` calls
2. **Upgrade libusb** to 1.0.23+ for `libusb_wrap_sys_device()`
3. **Add manifest permissions** - FGS connected device type

### Short-term (P1)

1. **Harden buffer operations** - Bounds checking on frame copy
2. **Add integer overflow checks** - Size calculations
3. **Enable Clang-Tidy** - Build-time enforcement

### Long-term (P2)

1. **Migrate to std::mdspan** - Type-safe buffer access
2. **Fuzz testing** - Frame processing, JNI boundary
3. **Security audit** - Third-party penetration test

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-001** | USB access vulnerabilities |
| **SECURITY-002** | FD injection mitigation |
| **SECURITY-003** | JNI safety mitigations |
| **SECURITY-007** | MTE compatibility |
| **SAFETY-002** | Buffer overflow vulnerabilities |
| **SAFETY-009** | Master hazard catalog |

---

*End of SECURITY-010*
