# JNI-002: Handle Leak Detection

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** jlong pointer cast analysis and leak detection
**Status:** Complete

---

## Summary

| Metric | Value |
|--------|-------|
| Handle Types Analyzed | 4 |
| HandleManager Usage | 2 types (Camera, RingBuffer) |
| Legacy Casts | 3 locations |
| Leak Risk | Medium (EGL handles) |

---

## 1. HandleManager Pattern (Modern - MTE-Safe)

The codebase implements a modern HandleManager pattern that prevents the classic "Handle Leak" vulnerability.

### 1.1 Pattern Overview

```cpp
// Registration: Create generation-encoded handle
int64_t handle = getHandleManager().registerContext(ptr);

// Acquisition: Thread-safe with ScopedRef
auto ref = getHandleManager().acquire(handle);
if (!ref) {
    return JNI_ERR_INVALID_HANDLE;
}

// Destruction: Blocks until all refs drained
void* ctx = getHandleManager().invalidateAndFree(handle);
delete ctx;
```

### 1.2 Registered Handle Types

| Type | Manager | Registration | Destruction |
|------|---------|--------------|-------------|
| UVCCamera | `getCameraHandleManager()` | `nativeCreate` (line 129) | `nativeDestroy` (line 149) |
| FrameBufferRing | `getRingBufferHandleManager()` | `nativeFrameBufferAllocate` (line 126) | `nativeFrameBufferDestroy` (line 157) |

### 1.3 Generation-Encoded Handle Format

```
Handle Format (64-bit):
┌────────────────────────────────────────────────────────────────────────┐
│ Bits 63-32: Generation Counter │ Bits 31-0: Slot Index                 │
└────────────────────────────────────────────────────────────────────────┘

Example: 0x0001_0003 = Generation 1, Slot 3
```

**Security Properties:**
- Use-after-free: Generation mismatch fails validation
- MTE compliance: No raw pointer exposure to Java
- Thread safety: Atomic ref counting with spin-wait on destroy

---

## 2. Legacy Handle Patterns (Risk Analysis)

### 2.1 EGL Handle Casts (MEDIUM RISK)

**Location:** `EGLImageHelperJNI.cpp`

| Function | Line | Type | Risk |
|----------|------|------|------|
| `nativeCreateEGLImageFromHardwareBuffer` | 282 | EGLImageKHR → jlong | Medium |
| `nativeImportNativeFence` | 419 | EGLSyncKHR → jlong | Medium |

**Code Pattern:**
```cpp
// EGLImageHelperJNI.cpp:282 - LEGACY PATTERN
return reinterpret_cast<jlong>(image);

// EGLImageHelperJNI.cpp:419 - LEGACY PATTERN
return reinterpret_cast<jlong>(sync);
```

**Mitigating Factors:**
- Kotlin layer has explicit destroy calls (`nativeDestroyEGLImage`, `nativeDestroySync`)
- EGL handles are GPU resources, not pointers to heap memory
- Android EGL driver manages actual resource lifecycle
- No MTE tag stripping issues (EGL handles are opaque integers)

**Risk Assessment:**
- **Memory leak:** If Kotlin fails to call destroy
- **Use-after-free:** Possible if Kotlin uses handle after destroy
- **MTE violation:** Low (EGL handles are not tagged pointers)

### 2.2 Internal Pointer Return (LOW RISK)

**Location:** `UVCCamera.cpp:758`

```cpp
jlong UVCCamera::getRingBufferHandle() {
    if (mPreview) {
        FrameBufferRing *ring = mPreview->getFrameBufferRing();
        RETURN(reinterpret_cast<jlong>(ring), jlong);
    }
    RETURN(0, jlong);
}
```

**Mitigating Factors:**
- This pointer is **not exposed to Java** directly
- It's used internally by the JNI layer to get the ring buffer handle
- The ring buffer lifecycle is tied to UVCCamera lifecycle
- Consumer access goes through HandleManager-protected `nativeSetFrameBufferRing`

**Risk Assessment:**
- **Memory leak:** None (owned by parent)
- **Use-after-free:** Protected by HandleManager in calling code
- **MTE violation:** Possible if used directly (but it's not)

### 2.3 Numeric Returns (NO RISK)

The following `static_cast<jlong>` patterns are **NOT handle leaks** - they return numeric values:

| File | Line | Type | Purpose |
|------|------|------|---------|
| FrameBufferJNI.cpp | 306 | frameNumber | Counter |
| FrameBufferJNI.cpp | 401 | framesReceived | Counter |
| FrameBufferJNI.cpp | 414 | framesRendered | Counter |
| FrameBufferJNI.cpp | 427 | framesDropped | Counter |
| serenegiant_usb_UVCCamera.cpp | 755 | droppedNoSurface | Counter |
| serenegiant_usb_UVCCamera.cpp | 769 | droppedQueueFull | Counter |
| serenegiant_usb_UVCCamera.cpp | 783 | totalFramesProcessed | Counter |

---

## 3. Handle Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HANDLE LIFECYCLE FLOW                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  CAMERA HANDLE (HandleManager - SAFE)                                        │
│  ─────────────────────────────────────                                       │
│  Kotlin: UVCCamera()                                                         │
│       │                                                                      │
│       ▼ nativeCreate()                                                       │
│  ┌─────────────────────────────────────────┐                                 │
│  │ UVCCamera *camera = new UVCCamera();    │                                 │
│  │ handle = registerContext(camera);       │  ← Generation-encoded handle   │
│  │ return handle;                          │                                 │
│  └─────────────────────────────────────────┘                                 │
│       │                                                                      │
│       ▼ All JNI calls                                                        │
│  ┌─────────────────────────────────────────┐                                 │
│  │ auto ref = acquire(handle);             │  ← ScopedRef blocks destroy     │
│  │ if (!ref) return ERROR;                 │                                 │
│  │ camera->doWork();                       │                                 │
│  │ // ref destructor decrements refcount   │                                 │
│  └─────────────────────────────────────────┘                                 │
│       │                                                                      │
│       ▼ nativeDestroy()                                                      │
│  ┌─────────────────────────────────────────┐                                 │
│  │ ctx = invalidateAndFree(handle);        │  ← Spins until refs == 0       │
│  │ delete ctx;                             │                                 │
│  └─────────────────────────────────────────┘                                 │
│                                                                              │
│                                                                              │
│  EGL HANDLE (Direct Cast - MEDIUM RISK)                                      │
│  ──────────────────────────────────────                                      │
│  Kotlin: EGLImageHelper.createEGLImage(buffer)                               │
│       │                                                                      │
│       ▼ nativeCreateEGLImageFromHardwareBuffer()                             │
│  ┌─────────────────────────────────────────┐                                 │
│  │ EGLImageKHR image = eglCreateImageKHR();│                                 │
│  │ return reinterpret_cast<jlong>(image);  │  ← Raw handle exposure          │
│  └─────────────────────────────────────────┘                                 │
│       │                                                                      │
│       ▼ Kotlin stores handle as Long                                         │
│       │                                                                      │
│       ▼ nativeDestroyEGLImage()                                              │
│  ┌─────────────────────────────────────────┐                                 │
│  │ EGLImageKHR img = reinterpret_cast(...);│                                 │
│  │ eglDestroyImageKHR(display, img);       │  ← Kotlin must ensure call     │
│  └─────────────────────────────────────────┘                                 │
│                                                                              │
│  ⚠️ RISK: Kotlin must guarantee destroy is called (e.g., in close/finalize) │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Findings Summary

| ID | Severity | Finding | Location | Recommendation |
|----|----------|---------|----------|----------------|
| JNI-002-001 | Info | HandleManager used for Camera handles | serenegiant_usb_UVCCamera.cpp:129 | Keep |
| JNI-002-002 | Info | HandleManager used for RingBuffer handles | FrameBufferJNI.cpp:126 | Keep |
| JNI-002-003 | Medium | EGLImage handle uses direct cast | EGLImageHelperJNI.cpp:282 | Consider HandleManager |
| JNI-002-004 | Medium | EGLSync handle uses direct cast | EGLImageHelperJNI.cpp:419 | Consider HandleManager |
| JNI-002-005 | Low | Internal ring pointer returned | UVCCamera.cpp:758 | Document lifecycle |
| JNI-002-006 | Info | Generation encoding prevents use-after-free | HandleManager.h | Exemplary pattern |

---

## 5. Recommendations

### 5.1 EGL Handle Migration (Optional)

The EGL handles could be migrated to HandleManager, but this is **optional** because:
1. EGL handles are GPU resources, not heap pointers
2. The Android EGL driver manages actual resource lifecycle
3. MTE doesn't affect these handles (they're opaque integers)
4. Kotlin already has explicit lifecycle management

**If migrating:**
```cpp
// Create EGL-specific HandleManager
static HandleManager<16>& getEGLImageHandleManager() {
    static HandleManager<16> manager;
    return manager;
}

// In nativeCreateEGLImageFromHardwareBuffer:
EGLImageKHR image = eglCreateImageKHR(...);
return getEGLImageHandleManager().registerContext(image);

// In nativeDestroyEGLImage:
void* ctx = getEGLImageHandleManager().invalidateAndFree(handle);
if (ctx) {
    eglDestroyImageKHR(display, reinterpret_cast<EGLImageKHR>(ctx));
}
```

### 5.2 Kotlin Layer Hardening

Ensure Kotlin layer handles cleanup:
```kotlin
class EGLImageWrapper(private val display: EGLDisplay, buffer: HardwareBuffer) : AutoCloseable {
    private var handle: Long = EGLImageHelper.nativeCreateEGLImageFromHardwareBuffer(display, buffer)

    override fun close() {
        if (handle != 0L) {
            EGLImageHelper.nativeDestroyEGLImage(display, handle)
            handle = 0L
        }
    }

    protected fun finalize() {
        if (handle != 0L) {
            Log.w(TAG, "EGLImageWrapper leaked - was not closed properly")
            close()
        }
    }
}
```

---

## 6. Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-003** | Original handle leak analysis (AUDIT-004) |
| **HandleManager.h** | Implementation reference |
| **FrameBufferJNI.cpp:123** | ScopedRef acquisition example |
| **JNI-001** | Function inventory |

---

## Raw Data

| Pattern | Count |
|---------|-------|
| `registerContext` calls | 2 |
| `invalidateAndFree` calls | 2 |
| `reinterpret_cast<jlong>` | 3 |
| `static_cast<jlong>` (numeric) | 14 |

---

*End of JNI-002*
