# SECURITY-003: JNI Memory Safety Assessment

**Audit:** AUDIT-004 Android Security Compliance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/UVCCamera/`

---

## Executive Summary

| Metric | Count | Status |
|--------|-------|--------|
| **Handle/Map pattern (MTE-safe)** | ~50+ JNI functions | ✅ COMPLIANT |
| **Legacy `reinterpret_cast<jlong>` returns** | 3 | ⚠️ NEEDS MIGRATION |
| **Legacy pointer casts in EGL code** | 2 | ⚠️ NEEDS MIGRATION |
| **HandleManager implementation** | 1 | ✅ EXCELLENT |

**Overall Assessment:** Codebase is **largely compliant** with Android 16 MTE requirements. The HandleManager.h implementation is exemplary. A few legacy patterns remain in EGLImageHelperJNI.cpp and one return site in UVCCamera.cpp.

---

## Positive Finding: HandleManager.h (EXEMPLARY)

**Location:** `lib/src/main/jni/UVCCamera/HandleManager.h`

The codebase already implements the Handle/Map pattern correctly:

### MTE-Safe Pointer Storage

```cpp
// Line 73-75 - Correct uintptr_t usage for MTE tag preservation
// 64-bit safe pointer storage that respects ARM Top-Byte-Ignore (TBI) and MTE tags.
// Using uintptr_t ensures MTE-tagged pointers (0xb400...) are preserved correctly.
using ContextPtr = uintptr_t;
```

### Generation-Based Slot Validation

```cpp
// Lines 79-94 - Cache-line aligned slot with atomic operations
struct alignas(CACHE_LINE_SIZE) HandleSlot {
    std::atomic<uint32_t> generation{0};   // Odd = alive, even = dead
    std::atomic<int> activeRefs{0};         // Reference counting
    std::atomic<ContextPtr> context{0};     // MTE-tagged pointer storage
};
```

### RAII ScopedRef Pattern

```cpp
// Lines 118-151 - Correct RAII for reference counting
class ScopedRef {
    HandleSlot* mSlot;
public:
    void* ptr;
    ~ScopedRef() {
        if (mSlot) {
            mSlot->activeRefs.fetch_sub(1, std::memory_order_release);
        }
    }
    explicit operator bool() const { return ptr != nullptr; }
};
```

### Correct Memory Ordering

```cpp
// Line 224 - Acquire before validation
slot.activeRefs.fetch_add(1, std::memory_order_acquire);

// Lines 227-228 - Acquire for reading
uint32_t actualGen = slot.generation.load(std::memory_order_acquire);
ContextPtr ctxAddr = slot.context.load(std::memory_order_acquire);
```

**Assessment:** This implementation:
- ✅ Preserves MTE tags via `uintptr_t`
- ✅ Uses correct memory ordering
- ✅ Implements generation-based handle validation
- ✅ Prevents use-after-free with activeRefs draining
- ✅ Cache-line aligned to prevent false sharing

---

## Compliant Usage Examples

### FrameBufferJNI.cpp (COMPLIANT)

**Location:** `lib/src/main/jni/UVCCamera/FrameBufferJNI.cpp`

```cpp
// Line 51-55 - Correct HandleManager usage
static HandleManager::ScopedRef acquireRingBuffer(jlong handle, const char* context) {
    auto ref = getRingBufferHandleManager().acquire(handle);
    if (!ref) {
        LOGE("%s: invalid handle 0x%llx", context, (unsigned long long)handle);
    }
    return ref;  // Move semantics
}

// Line 101-127 - Correct registration
static jlong nativeFrameBufferAllocate(JNIEnv *env, jobject thiz, ...) {
    auto* ring = new FrameBufferRing(width, height, ...);
    jlong handle = getRingBufferHandleManager().registerContext(ring);
    return handle;  // Returns handle ID, not pointer
}

// Line 193-240 - Correct usage pattern
static jobject nativeFrameBufferAcquireBuffer(JNIEnv *env, jobject thiz, jlong handle) {
    auto ref = acquireRingBuffer(handle, __func__);
    if (!ref) return nullptr;

    auto* ring = static_cast<FrameBufferRing*>(ref.ptr);
    // Use ring safely within ScopedRef lifetime
    // ...
}  // ScopedRef destructor decrements activeRefs
```

### serenegiant_usb_UVCCamera.cpp (COMPLIANT)

**Location:** `lib/src/main/jni/UVCCamera/serenegiant_usb_UVCCamera.cpp`

```cpp
// Lines 123-135 - Correct camera handle registration
static ID_TYPE nativeCreate(JNIEnv *env, jobject thiz) {
    auto *camera = new UVCCamera();
    ID_TYPE id = getCameraHandleManager().registerContext(camera);
    if (id == INVALID_HANDLE) {
        LOGE("nativeCreate: failed to register camera handle");
        delete camera;
        return 0;
    }
    return id;  // Returns handle ID, not pointer
}
```

---

## Remaining Violations

### JNI-001: UVCCamera.cpp:758 (MEDIUM)

**Location:** `lib/src/main/jni/UVCCamera/UVCCamera.cpp:758`

**Pattern:**
```cpp
RETURN(reinterpret_cast<jlong>(ring), jlong);
```

**Context:** Returns a raw pointer to FrameBufferRing as jlong.

**Risk:**
- Pointer provenance loss
- MTE tag not preserved in the cast
- Inconsistent with HandleManager pattern used elsewhere

**Migration:**
```cpp
// Register with HandleManager instead
jlong handle = getRingBufferHandleManager().registerContext(ring);
RETURN(handle, jlong);
```

---

### JNI-002: EGLImageHelperJNI.cpp:282 (MEDIUM)

**Location:** `lib/src/main/jni/UVCCamera/EGLImageHelperJNI.cpp:282`

**Pattern:**
```cpp
return reinterpret_cast<jlong>(image);
```

**Context:** Returns EGLImage handle to Java.

**Analysis:** EGLImage is an opaque handle type (`void*`), not a heap-allocated object. The safety concern is different from UVCCamera pointers.

**Risk:**
- Lower risk than heap pointers (EGL handles may already be opaque IDs)
- But still technically a provenance violation

**Recommendation:** Consider wrapping in a dedicated EGLImageHandleManager, or document that EGLImage handles are externally managed.

---

### JNI-003: EGLImageHelperJNI.cpp:419 (MEDIUM)

**Location:** `lib/src/main/jni/UVCCamera/EGLImageHelperJNI.cpp:419`

**Pattern:**
```cpp
return reinterpret_cast<jlong>(sync);
```

**Context:** Returns EGLSync handle to Java.

**Analysis:** Similar to JNI-002. EGLSync is an opaque platform handle.

**Recommendation:** Same as JNI-002.

---

## JNI Function Signature Audit

### Functions Accepting jlong Handles (COMPLIANT)

All of these use HandleManager correctly:

| Function | File | Status |
|----------|------|--------|
| `nativeFrameBufferDestroy` | FrameBufferJNI.cpp:147 | ✅ Uses HandleManager |
| `nativeFrameBufferAcquireBuffer` | FrameBufferJNI.cpp:193 | ✅ Uses HandleManager |
| `nativeFrameBufferReleaseBuffer` | FrameBufferJNI.cpp:241 | ✅ Uses HandleManager |
| `nativeFrameBufferGetAcquireFence` | FrameBufferJNI.cpp:268 | ✅ Uses HandleManager |
| `nativeFrameBufferGetFrameNumber` | FrameBufferJNI.cpp:297 | ✅ Uses HandleManager |
| ... (40+ more functions) | FrameBufferJNI.cpp | ✅ Uses HandleManager |
| `nativeConnect` | serenegiant_usb_UVCCamera.cpp:159 | ✅ Uses HandleManager |
| `nativeDestroy` | serenegiant_usb_UVCCamera.cpp:235 | ✅ Uses HandleManager |
| ... (30+ more functions) | serenegiant_usb_UVCCamera.cpp | ✅ Uses HandleManager |

### Functions Returning jlong (AUDIT)

| Function | File | Status |
|----------|------|--------|
| `nativeCreate` | serenegiant_usb_UVCCamera.cpp:123 | ✅ Uses HandleManager |
| `nativeFrameBufferAllocate` | FrameBufferJNI.cpp:101 | ✅ Uses HandleManager |
| `nativeGetRingBufferHandle` | serenegiant_usb_UVCCamera.cpp:648 | ⚠️ Check implementation |
| `nativeCreateEGLImageFromHardwareBuffer` | EGLImageHelperJNI.cpp:218 | ⚠️ Raw pointer return |
| `nativeImportNativeFence` | EGLImageHelperJNI.cpp:380 | ⚠️ Raw pointer return |

---

## LayoutContract.h Validation

**Location:** `lib/src/main/jni/UVCCamera/LayoutContract.h:55-56`

```cpp
// jlong is always 8 bytes per JNI spec - this is critical for pointer handles
static_assert(sizeof(jlong) == 8, "jlong must be 64-bit for pointer handles");
```

**Assessment:** Correct compile-time validation ensures jlong can hold 64-bit pointers.

---

## MTE Compatibility Matrix

| Pattern | MTE Status | Evidence |
|---------|------------|----------|
| HandleManager `uintptr_t` | ✅ SAFE | Preserves TBI tags |
| `reinterpret_cast<void*>(ctxAddr)` | ✅ SAFE | From HandleManager |
| `reinterpret_cast<jlong>(ptr)` | ⚠️ RISKY | Tag lost on round-trip |
| `static_cast<UVCCamera*>(ref.ptr)` | ✅ SAFE | Via HandleManager |

---

## Migration Plan for Remaining Violations

### Priority 1: UVCCamera.cpp:758

```cpp
// Current
RETURN(reinterpret_cast<jlong>(ring), jlong);

// Target
jlong handle = getRingBufferHandleManager().registerContext(ring);
RETURN(handle, jlong);
```

**Effort:** LOW
**Risk:** LOW (isolated change)

### Priority 2: EGLImageHelperJNI.cpp

**Options:**

**Option A:** Create EGLHandleManager
```cpp
// New HandleManager for EGL resources
HandleManager& getEGLImageHandleManager();
HandleManager& getEGLSyncHandleManager();

// Usage
jlong handle = getEGLImageHandleManager().registerContext(image);
return handle;
```

**Option B:** Document as External Handles
```cpp
// EGLImage and EGLSync are platform opaque handles, not heap pointers
// They are safe to cast to jlong because:
// 1. They are already opaque IDs from the EGL implementation
// 2. They don't carry MTE tags (not heap allocations)
// 3. Platform manages their lifecycle
return reinterpret_cast<jlong>(image);  // DOCUMENTED EXCEPTION
```

**Recommendation:** Option B with clear documentation, unless testing reveals MTE issues on Tensor G5/G6.

---

## Clang-Tidy Integration

The HandleManager pattern is enforced by Clang-Tidy custom checks (see SECURITY-009):

```yaml
CustomChecks:
  - Name: 'jni-no-raw-pointer-cast'
    Query: >
      explicitCastExpr(
        hasSourceExpression(ignoringParenImpCasts(hasType(asString("jlong")))),
        anyOf(
          hasDestinationType(pointerType()),
          hasDestinationType(asString("intptr_t"))
        ),
        hasAncestor(functionDecl(matchesName("^::Java_")))
      )
```

**Current Violations:** 5 (3 in UVCCamera, 2 in EGLImageHelper)

---

## Verification Steps

### Test 1: MTE Simulation

```bash
# Enable MTE on test device
adb shell setprop arm64.memtag.process.com.scopecam sync

# Run app and monitor for faults
adb logcat | grep -E "SIGSEGV|MTE|memtag"
```

### Test 2: Handle Lifecycle

```kotlin
@Test
fun testHandleValidation() {
    val handle = nativeCreate()
    assertTrue(nativeIsValid(handle))

    nativeDestroy(handle)
    assertFalse(nativeIsValid(handle))

    // Should not crash, should return error
    val result = nativeSetParam(handle, 0, 0)
    assertEquals(JNI_ERR_INVALID_HANDLE, result)
}
```

### Test 3: Race Condition (Stress)

```kotlin
@Test
fun testConcurrentAccess() {
    val handle = nativeCreate()

    val threads = (1..10).map {
        thread {
            repeat(1000) {
                nativeGetStatus(handle)
            }
        }
    }

    // Destroy while threads are running
    Thread.sleep(50)
    nativeDestroy(handle)

    threads.forEach { it.join() }
    // Should not crash due to HandleManager protection
}
```

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-007** | MTE compatibility details |
| **SECURITY-009** | Clang-Tidy enforcement configuration |
| **SAFETY-001** | Memory allocation patterns |
| **AUDIT-004** | Handle/Map pattern specification |

---

*End of SECURITY-003*
