# SECURITY-007: Memory Tagging Extension (MTE) Compatibility Assessment

**Audit:** AUDIT-004 Android Security Compliance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/UVCCamera/`

---

## Executive Summary

| Assessment Area | Status | Notes |
|-----------------|--------|-------|
| **HandleManager.h** | ✅ MTE-SAFE | Exemplary `uintptr_t` usage |
| **JNI Handle Pattern** | ✅ COMPLIANT | Uses Handle/Map registry |
| **Legacy Pointer Casts** | ⚠️ 3 remaining | See SECURITY-003 |
| **Buffer Operations** | ✅ Generally safe | Uses std::span patterns |
| **EGL Handle Returns** | ⚠️ Review needed | May be platform opaque |

**Overall Assessment:** Codebase is **largely MTE-compatible**. The HandleManager implementation is exemplary.

---

## MTE Background

### What is MTE?

Memory Tagging Extension (MTE) is an ARMv8.5-A/ARMv9 feature that:
- Tags memory allocations with 4-bit identifiers
- Tags pointers with matching 4-bit values
- Hardware verifies tag match on every memory access
- Detects use-after-free, buffer overflow, and stale pointers

### MTE on Android

| Device | SoC | MTE Status |
|--------|-----|------------|
| Pixel 8/9 | Tensor G3/G4 | Async MTE available |
| Pixel 10 | Tensor G5 | Sync MTE default for system apps |
| Galaxy S25 | Exynos 2500 | MTE support expected |

### MTE Modes

| Mode | Behavior | Performance |
|------|----------|-------------|
| `off` | MTE disabled | Baseline |
| `async` | Faults queued, reported later | ~2% overhead |
| `sync` | Immediate fault on mismatch | ~10% overhead |

---

## MTE-Safe Patterns in Codebase

### HandleManager.h (EXEMPLARY)

**Location:** `lib/src/main/jni/UVCCamera/HandleManager.h`

```cpp
// Line 73-75 - Correct uintptr_t usage
// 64-bit safe pointer storage that respects ARM Top-Byte-Ignore (TBI) and MTE tags.
// Using uintptr_t ensures MTE-tagged pointers (0xb400...) are preserved correctly.
using ContextPtr = uintptr_t;

// Line 89-91 - Atomic storage preserves tags
std::atomic<ContextPtr> context{0};

// Line 165 - Strict cast preserves MTE tags
ContextPtr ctxAddr = reinterpret_cast<ContextPtr>(ctx);

// Line 233 - Cast back preserves tags
return {&slot, reinterpret_cast<void*>(ctxAddr)};
```

**Analysis:**
- ✅ Uses `uintptr_t` (not `jlong`) for internal storage
- ✅ Atomic operations preserve all 64 bits including TBI
- ✅ `reinterpret_cast<void*>(uintptr_t)` preserves MTE tags

### Why This Works

```
MTE-Tagged Pointer: 0xb4007fff12345678
                    ├─┤
                    Tag (4 bits in TBI region)

Storage as uintptr_t: All 64 bits preserved
Retrieval: Cast back to void* - tag intact
Hardware check: Tag matches allocation - SUCCESS
```

---

## MTE-Unsafe Patterns

### Pattern 1: jlong Round-Trip (RISKY)

**Hazard:**
```cpp
// Allocation
MyObject* obj = new MyObject();
// obj has MTE tag: 0xb400...

jlong handle = reinterpret_cast<jlong>(obj);
// Tag is preserved in jlong... BUT

// In a different JNI function:
MyObject* ptr = reinterpret_cast<MyObject*>(handle);
// Compiler may not recognize this as same allocation
// Provenance is lost
// MTE check MAY fail depending on compiler optimizations
```

### Pattern 2: intptr_t Intermediate (DANGEROUS on ILP32)

**Hazard:**
```cpp
// On 32-bit ARM (ARMv7, rare but possible)
jlong handle = 0x00000001_FFFFFFFF;  // 8 bytes
intptr_t intermediate = (intptr_t)handle;  // TRUNCATION to 4 bytes!
void* ptr = (void*)intermediate;  // Wrong address
```

### Pattern 3: Integer Arithmetic on Pointers

**Hazard:**
```cpp
// Pointer arithmetic via integers loses provenance
uint8_t* base = ...;
size_t offset = 100;
uint8_t* target = (uint8_t*)(((uintptr_t)base) + offset);
// MTE may fail - provenance unclear
```

**Safe Alternative:**
```cpp
uint8_t* target = base + offset;  // Direct pointer arithmetic
// OR
std::span<uint8_t> view(base, size);
uint8_t value = view[offset];  // Bounds-checked access
```

---

## Remaining MTE-Unsafe Code

### JNI-001: UVCCamera.cpp:758

```cpp
RETURN(reinterpret_cast<jlong>(ring), jlong);
```

**MTE Impact:** Moderate - pointer stored in jlong may lose provenance on round-trip.

**Mitigation:** Use HandleManager (already implemented for other objects).

### JNI-002/003: EGLImageHelperJNI.cpp:282, 419

```cpp
return reinterpret_cast<jlong>(image);
return reinterpret_cast<jlong>(sync);
```

**MTE Impact:** Low - EGLImage and EGLSync are platform opaque handles, likely not MTE-tagged heap allocations.

**Recommendation:** Test on Tensor G5/G6; add HandleManager if issues found.

---

## MTE Testing Configuration

### Enable MTE for App

**AndroidManifest.xml:**
```xml
<application android:memtagMode="sync">
```

**Options:**
| Value | Behavior |
|-------|----------|
| `off` | MTE disabled |
| `async` | Async checking (production) |
| `sync` | Sync checking (testing) |

### ADB Override for Testing

```bash
# Enable sync MTE for specific process
adb shell setprop arm64.memtag.process.com.serenegiant.uvccamera sync

# Or for all processes (requires root)
adb shell setprop arm64.memtag.default sync
```

### Monitor for MTE Faults

```bash
# Watch for MTE-related signals
adb logcat | grep -E "SIGSEGV|MTE|memtag|tag.mismatch"

# Detailed tombstone analysis
adb shell cat /data/tombstones/tombstone_* | grep -A 20 "MTE"
```

---

## MTE Fault Signatures

### Use-After-Free

```
signal 11 (SIGSEGV), code 9 (SEGV_MTEAERR), fault addr 0xb4007fff1234
    MTE tag mismatch: pointer tag 0xb4, memory tag 0x00
    Cause: memory was freed, tag cleared
```

### Buffer Overflow

```
signal 11 (SIGSEGV), code 9 (SEGV_MTESERR), fault addr 0xb5007fff1300
    MTE tag mismatch: pointer tag 0xb5, memory tag 0xb4
    Cause: overflow into adjacent allocation with different tag
```

### Stale Handle

```
signal 11 (SIGSEGV), code 9 (SEGV_MTEAERR), fault addr 0xb4007fff5678
    MTE tag mismatch: pointer tag 0xb4, memory tag 0xb7
    Cause: memory reallocated with new tag, old pointer still in use
```

---

## MTE Compatibility Checklist

### ✅ Safe Patterns

| Pattern | Assessment |
|---------|------------|
| HandleManager slot-based lookup | SAFE - provenance preserved |
| `std::unique_ptr` ownership | SAFE - RAII cleanup |
| `std::span` buffer access | SAFE - bounds checked |
| Direct pointer arithmetic | SAFE - provenance tracked |
| `reinterpret_cast` for byte access | SAFE - aliasing rules |

### ⚠️ Review Patterns

| Pattern | Assessment |
|---------|------------|
| `jlong` pointer storage | REVIEW - use HandleManager |
| Platform opaque handles (EGL) | REVIEW - test on device |
| Third-party library allocations | REVIEW - verify ownership |

### ❌ Unsafe Patterns

| Pattern | Assessment |
|---------|------------|
| Integer-to-pointer cast | UNSAFE - no provenance |
| Pointer-to-integer-to-pointer | UNSAFE - provenance lost |
| `intptr_t` intermediate on ILP32 | UNSAFE - truncation |

---

## Performance Considerations

### MTE Overhead

| Mode | CPU Overhead | Memory Overhead |
|------|-------------|-----------------|
| `async` | ~2% | ~3% (tags) |
| `sync` | ~10% | ~3% (tags) |

### Optimization for MTE

```cpp
// Avoid in hot paths:
void* ptr = reinterpret_cast<void*>(integer_value);  // Tag missing

// Prefer:
auto& obj = *registry.get(handle);  // Provenance preserved
```

### Frame Processing Impact

For 60fps frame processing:
- HandleManager lookup: ~10ns
- MTE tag check: ~1ns (hardware)
- **Negligible impact** on frame rate

---

## Testing Strategy

### Unit Test: MTE Tag Preservation

```cpp
TEST(MteCompatibility, HandleManagerPreservesTags) {
    auto* obj = new TestObject();

    // Get MTE-tagged address
    uintptr_t tagged_addr = reinterpret_cast<uintptr_t>(obj);

    // Register and retrieve
    auto& manager = getTestHandleManager();
    jlong handle = manager.registerContext(obj);
    auto ref = manager.acquire(handle);

    // Verify same address (including tag)
    uintptr_t retrieved_addr = reinterpret_cast<uintptr_t>(ref.ptr);
    EXPECT_EQ(tagged_addr, retrieved_addr);

    manager.invalidateAndFree(handle);
}
```

### Integration Test: Full JNI Cycle

```kotlin
@Test
fun testMteSafeJniCycle() {
    // Create
    val handle = nativeCreate()
    assertTrue(handle != 0L)

    // Use multiple times
    repeat(100) {
        nativeGetStatus(handle)
    }

    // Destroy
    nativeDestroy(handle)

    // Should not crash on stale handle
    val result = nativeGetStatus(handle)
    assertEquals(JNI_ERR_INVALID_HANDLE, result)
}
```

### Stress Test: Concurrent Access

```kotlin
@Test
fun testMteConcurrentAccess() {
    val handle = nativeCreate()

    // Hammer from multiple threads
    val threads = (1..10).map {
        thread {
            repeat(1000) {
                nativeGetStatus(handle)
            }
        }
    }

    threads.forEach { it.join() }
    nativeDestroy(handle)

    // No MTE faults should occur
}
```

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-003** | JNI pointer cast catalog |
| **SECURITY-009** | Clang-Tidy MTE enforcement |
| **SAFETY-001** | Memory allocation patterns |
| **AUDIT-004** | MTE background and hazards |

---

*End of SECURITY-007*
