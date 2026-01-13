# JNI-004: Lifecycle Management Audit

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** Camera and preview lifecycle state management
**Status:** Complete

---

## Summary

| Metric | Value |
|--------|-------|
| State Machines | 2 |
| Preview States | 3 (COLD, WARM, HOT) |
| Cleanup Levels | 4 |
| GlobalRef Callbacks | 5 |

---

## 1. Preview State Machine

### 1.1 States

**Location:** `UVCPreview.h`

```cpp
enum class PreviewState : int {
    COLD = 0,    // No USB, no threads
    WARM = 1,    // USB running, no surface (frames drained/stashed)
    HOT  = 2     // USB + surface - full rendering
};
```

### 1.2 State Transition Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       PREVIEW STATE MACHINE                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│                              ┌───────────┐                                   │
│                              │   COLD    │                                   │
│                              │           │                                   │
│                              │ No USB    │                                   │
│                              │ No Thread │                                   │
│                              └─────┬─────┘                                   │
│                                    │                                         │
│                         startPreview()                                       │
│                           (surface?)                                         │
│                                    │                                         │
│                    ┌───────────────┴───────────────┐                        │
│                    │                               │                        │
│              (no surface)                    (has surface)                  │
│                    │                               │                        │
│                    ▼                               ▼                        │
│            ┌───────────────┐               ┌───────────────┐                │
│            │     WARM      │◄─────────────►│      HOT      │                │
│            │               │ detachSurface │               │                │
│            │ USB streaming │──────────────►│ USB streaming │                │
│            │ No rendering  │               │ Full render   │                │
│            │ Capture works │◄──────────────│ Capture works │                │
│            └───────┬───────┘ attachSurface └───────┬───────┘                │
│                    │                               │                        │
│                    │                               │                        │
│                    └────────────┬──────────────────┘                        │
│                                 │                                           │
│                          stopPreview()                                      │
│                                 │                                           │
│                                 ▼                                           │
│                            ┌───────────┐                                    │
│                            │   COLD    │                                    │
│                            └───────────┘                                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 State Properties

| State | USB | Thread | Surface | Capture | Display |
|-------|-----|--------|---------|---------|---------|
| COLD | No | No | No | No | No |
| WARM | Yes | Yes | No | **Yes** | No |
| HOT | Yes | Yes | Yes | **Yes** | **Yes** |

### 1.4 WARM State Value

The WARM state provides:
- **Instant resume:** No USB re-permission needed when returning from Gallery
- **Continuous capture:** Photo/ML capture works even without display
- **Thermal efficiency:** No GPU rendering load

---

## 2. Cleanup Level System

### 2.1 Cleanup Levels

**Location:** `UVCCamera.h`

```cpp
enum class CleanupLevel {
    PREVIEW_ONLY = 0,  // Stop preview, keep USB
    CAMERA = 1,        // Close camera handle
    INTERFACE = 2,     // Release USB interface
    FULL = 3           // Release everything
};
```

### 2.2 Graduated Cleanup

```
┌──────────────────────────────────────────────────────────────────────┐
│                     CLEANUP LEVEL HIERARCHY                           │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  Level 0: PREVIEW_ONLY                                                │
│  ├── Stop preview thread                                              │
│  ├── Clear callback references                                        │
│  └── Keep USB connection alive                                        │
│                                                                       │
│  Level 1: CAMERA                                                      │
│  ├── Close UVC device handle                                          │
│  ├── Free device context                                              │
│  └── Keep USB interface claimed                                       │
│                                                                       │
│  Level 2: INTERFACE                                                   │
│  ├── Release USB interface                                            │
│  ├── Detach kernel driver if attached                                 │
│  └── Keep libusb context                                              │
│                                                                       │
│  Level 3: FULL                                                        │
│  ├── Close libusb device                                              │
│  ├── Exit libusb context                                              │
│  └── Release all resources                                            │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.3 JNI Methods

| Method | Cleanup Action |
|--------|---------------|
| `nativeStopPreview` | PREVIEW_ONLY equivalent |
| `nativeCleanup(level)` | Explicit level selection |
| `nativeReleaseInterface` | INTERFACE level |
| `nativeRelease` | CAMERA level |
| `nativeDestroy` | HandleManager invalidation + delete |

---

## 3. GlobalRef Management

### 3.1 Callback References

| Callback | Creation | Cleanup |
|----------|----------|---------|
| Status | `serenegiant_usb_UVCCamera.cpp:253` | `UVCStatusCallback.cpp:36` |
| Button | `serenegiant_usb_UVCCamera.cpp:268` | `UVCButtonCallback.cpp:36` |
| Readiness | `serenegiant_usb_UVCCamera.cpp:283` | `UVCReadinessCallback.cpp:65` |
| Frame | `serenegiant_usb_UVCCamera.cpp:436` | `UVCPreview.cpp:280` |
| Capture | `UVCPreview.cpp:2251` | `UVCPreview.cpp:2244` |

### 3.2 GlobalRef Pattern

```cpp
// CREATION (in JNI method):
jobject callback_obj = env->NewGlobalRef(jCallback);
camera->setCallback(env, callback_obj);

// CLEANUP (in callback setter - replace):
if (mCallbackObj) {
    env->DeleteGlobalRef(mCallbackObj);
    mCallbackObj = NULL;
}
if (new_callback_obj) {
    mCallbackObj = env->NewGlobalRef(new_callback_obj);
}

// CLEANUP (in destructor):
if (mCallbackObj) {
    JNIEnv *env;
    getJNIEnv(&env);
    env->DeleteGlobalRef(mCallbackObj);
    mCallbackObj = NULL;
}
```

---

## 4. Lifecycle Flow

### 4.1 Normal Flow

```
Kotlin                    JNI                     Native
  │                        │                        │
  │  UVCCamera()           │                        │
  ├───────────────────────►│  nativeCreate()        │
  │                        ├───────────────────────►│ new UVCCamera
  │  ◄─────────────────────┤  return handle         │ registerContext
  │                        │                        │
  │  connect(fd)           │                        │
  ├───────────────────────►│  nativeConnectSimple() │
  │                        ├───────────────────────►│ USB init
  │                        │                        │
  │  startPreview()        │                        │
  ├───────────────────────►│  nativeStartPreview()  │
  │                        ├───────────────────────►│ → WARM/HOT
  │                        │                        │
  │  [Normal operation - frames flow]               │
  │                        │                        │
  │  detachSurface()       │                        │
  ├───────────────────────►│  nativeDetachSurface() │
  │                        ├───────────────────────►│ HOT → WARM
  │                        │                        │
  │  [Gallery, etc]        │                        │
  │                        │                        │
  │  attachSurface(s)      │                        │
  ├───────────────────────►│  nativeAttachSurface() │
  │                        ├───────────────────────►│ WARM → HOT
  │                        │                        │
  │  stopPreview()         │                        │
  ├───────────────────────►│  nativeStopPreview()   │
  │                        ├───────────────────────►│ → COLD
  │                        │                        │
  │  release()             │                        │
  ├───────────────────────►│  nativeRelease()       │
  │                        ├───────────────────────►│ Close UVC
  │                        │                        │
  │  close()               │                        │
  ├───────────────────────►│  nativeDestroy()       │
  │                        ├───────────────────────►│ delete camera
  │                        │                        │ invalidateAndFree
```

### 4.2 Error Recovery Flow

```
Kotlin                    JNI                     Native
  │                        │                        │
  │  [USB Disconnect]      │                        │
  │                        │        onError()       │
  │  ◄─────────────────────┼────────────────────────┤
  │                        │                        │
  │  cleanup(FULL)         │                        │
  ├───────────────────────►│  nativeCleanup(3)     │
  │                        ├───────────────────────►│ Full cleanup
  │                        │                        │
  │  destroy()             │                        │
  ├───────────────────────►│  nativeDestroy()       │
  │                        ├───────────────────────►│ Safe delete
```

---

## 5. Thread Safety

### 5.1 State Access

```cpp
// Atomic state with proper memory ordering
std::atomic<PreviewState> mPreviewState{PreviewState::COLD};

// Read (relaxed OK for display)
PreviewState state = mPreviewState.load(std::memory_order_acquire);

// Write (release to ensure visibility)
mPreviewState.store(PreviewState::WARM, std::memory_order_release);
```

### 5.2 HandleManager Protection

```cpp
// All JNI calls acquire ScopedRef
auto ref = getCameraHandleManager().acquire(id_camera);
if (!ref) {
    return JNI_ERR_INVALID_HANDLE;
}

// ScopedRef blocks destruction until JNI call completes
// See: HandleManager.h:43 - invalidateAndFree() spins until activeRefs == 0
```

---

## 6. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| JNI-004-001 | Info | 3-state machine well-designed | Keep |
| JNI-004-002 | Info | WARM state enables instant resume | Document for users |
| JNI-004-003 | Info | Graduated cleanup levels | Proper resource management |
| JNI-004-004 | Low | GlobalRef cleanup relies on destructor | Verify no JNI env issues |
| JNI-004-005 | Info | HandleManager protects against destroy-during-call | Robust |
| JNI-004-006 | Info | Atomic state with proper memory ordering | Thread-safe |

---

## 7. Cross-Reference

| Document | Relationship |
|----------|--------------|
| **PreviewState enum** | UVCPreview.h:51 |
| **CleanupLevel enum** | UVCCamera.h:41 |
| **HandleManager** | HandleManager.h |
| **JNI-002** | Handle lifecycle |
| **JNI-003** | Frame delivery states |

---

*End of JNI-004*
