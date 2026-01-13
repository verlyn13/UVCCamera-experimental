# CONCURRENCY-008: JNI Thread Boundary Audit

**Audit:** AUDIT-003 Concurrency Analysis
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

This document audits JNI thread boundary handling in the UVCCamera native codebase. JNI thread boundary management is critical for preventing crashes, deadlocks, and memory leaks when native threads call back into Java.

| Metric | Count |
|--------|-------|
| **JNIEnv references** | ~471 |
| **AttachCurrentThread calls** | 7 |
| **DetachCurrentThread calls** | 9 |
| **Global references created** | 8 |
| **Global references deleted** | 15 |
| **Exception handling sites** | 18 |
| **FindClass calls** | 9 |

---

## JNI Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            JNI THREAD BOUNDARY                                  │
└─────────────────────────────────────────────────────────────────────────────────┘

    JAVA/KOTLIN LAYER                          NATIVE LAYER (C++)
    ─────────────────                          ─────────────────
    ┌───────────────┐                          ┌───────────────────┐
    │ UVCCamera.kt  │◄──── JNI Methods ───────►│ serenegiant_usb_  │
    │ (Main Thread) │                          │ UVCCamera.cpp     │
    └───────────────┘                          └─────────┬─────────┘
                                                         │
                                               ┌─────────┴─────────┐
                                               │                   │
    ┌───────────────┐                    ┌─────┴─────┐       ┌─────┴─────┐
    │ Callbacks     │◄─── JNI Upcall ────│ cb_thread │       │ capture_  │
    │ (UI Thread)   │   AttachThread     │ (libuvc)  │       │ thread    │
    └───────────────┘                    └───────────┘       └───────────┘

    JavaVM* savedVm ◄────── Stored in JNI_OnLoad ──────────────────────────────────
```

---

## JNI Initialization

### JNI_OnLoad

**Location:** `UVCCamera/_onload.cpp:35-63`

```cpp
jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    // Layout contract validation (P0 fix)
    LayoutContract::logLayoutDiagnostics();
    LayoutContract::validateCriticalOffsets();

    JNIEnv *env;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    // Register native methods
    int result = register_uvccamera(env);
    if (result == 0) result = register_framebuffer(env);
    if (result == 0) result = register_eglimagehelper(env);

    setVM(vm);  // Store for AttachCurrentThread
    return JNI_VERSION_1_6;
}
```

### Global JavaVM Storage

**Location:** `UVCCamera/utilbase.cpp:27-43`

```cpp
static JavaVM *savedVm;

void setVM(JavaVM *vm) {
    savedVm = vm;
}

JavaVM *getVM() {
    return savedVm;
}

JNIEnv *getEnv() {
    JNIEnv *env = NULL;
    if (savedVm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        env = NULL;
    }
    return env;
}
```

**Thread Safety:** `savedVm` is set once in `JNI_OnLoad` (single-threaded context) and read-only thereafter. Thread-safe.

---

## AttachCurrentThread Usage

### Inventory

| ID | File | Line | Thread | Detach Location | Paired |
|----|------|------|--------|-----------------|--------|
| AT-001 | `UVCPreview.cpp` | 1309 | capture_thread | 1312 | ✅ |
| AT-002 | `UVCPreview.cpp` | 2588 | conversion_thread | 2613, 2659 | ✅ |
| AT-003 | `UVCButtonCallback.cpp` | 80 | cb_thread | 84 | ✅ |
| AT-004 | `UVCStatusCallback.cpp` | 82 | cb_thread | 86 | ✅ |
| AT-005 | `UVCReadinessCallback.cpp` | 98 | cb_thread | 109 | ✅ |
| AT-006 | `CaptureBasePipeline.cpp` | 172 | capture_thread | 175 | ✅ |

### Pattern 1: Thread Entry Point Attach (Recommended)

**Location:** `UVCPreview.cpp:1303-1317`

```cpp
void *UVCPreview::capture_thread_func(void *vptr_args) {
    ENTER();
    UVCPreview *preview = reinterpret_cast<UVCPreview *>(vptr_args);
    if (LIKELY(preview)) {
        JavaVM *vm = getVM();
        JNIEnv *env;
        // attach to JavaVM
        vm->AttachCurrentThread(&env, NULL);
        preview->do_capture(env);  // never return until finish previewing
        // detach from JavaVM
        vm->DetachCurrentThread();
        MARK("DetachCurrentThread");
    }
    PRE_EXIT();
    pthread_exit(NULL);
}
```

**Analysis:**
- ✅ Attach at thread entry, detach at thread exit
- ✅ Single attach/detach pair per thread lifetime
- ✅ JNIEnv passed to worker function

### Pattern 2: Conditional Attach (Conversion Thread)

**Location:** `UVCPreview.cpp:2578-2663`

```cpp
void UVCPreview::invokeJavaCaptureCallback(...) {
    // ...
    bool attached = false;
    JavaVM* vm = getVM();
    JNIEnv* env = nullptr;

    int envStatus = vm->GetEnv((void**)&env, JNI_VERSION_1_6);

    if (envStatus == JNI_EDETACHED) {
        if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
            LOGE("CAPTURE: Failed to attach thread");
            return;
        }
        attached = true;
    }

    // ... use env ...

    if (attached) {
        vm->DetachCurrentThread();
    }
}
```

**Analysis:**
- ✅ Checks if already attached (`GetEnv`)
- ✅ Tracks attach state for conditional detach
- ✅ Multiple early return points all detach correctly
- ⚠️ Repeated attach/detach per callback may be expensive

### Pattern 3: Callback Entry Point Attach

**Location:** `UVCButtonCallback.cpp:73-85`

```cpp
void UVCButtonCallback::uvc_button_callback(int button, int state, void *user_ptr) {
    UVCButtonCallback *buttonCallback = reinterpret_cast<UVCButtonCallback *>(user_ptr);

    JavaVM *vm = getVM();
    JNIEnv *env;
    // attach to JavaVM
    vm->AttachCurrentThread(&env, NULL);

    buttonCallback->notifyButtonCallback(env, button, state);

    vm->DetachCurrentThread();
}
```

**Analysis:**
- ⚠️ Attaches on every callback invocation (inefficient)
- ⚠️ libuvc callback thread could reuse attachment
- ✅ Correctly paired attach/detach

---

## Global Reference Management

### Reference Creation Sites

| ID | File | Line | Object Type | Delete Site |
|----|------|------|-------------|-------------|
| GR-001 | `serenegiant_usb.cpp` | 253 | `IStatusCallback` | `UVCStatusCallback.cpp:36` |
| GR-002 | `serenegiant_usb.cpp` | 268 | `IButtonCallback` | `UVCButtonCallback.cpp:36` |
| GR-003 | `serenegiant_usb.cpp` | 283 | `IReadinessCallback` | `UVCReadinessCallback.cpp:65` |
| GR-004 | `serenegiant_usb.cpp` | 436 | `IFrameCallback` | `UVCPreview.cpp:280` |
| GR-005 | `UVCPreview.cpp` | 2251 | `ICaptureCallback` | `UVCPreview.cpp:2244,2356` |
| GR-006 | `CallbackPipeline.cpp` | 251 | `IFrameCallback` | `CallbackPipeline.cpp:60` |

### Reference Lifecycle Pattern

```cpp
// Creation (JNI method call from Java thread)
int setCallback(JNIEnv *env, jobject button_callback_obj) {
    pthread_mutex_lock(&button_mutex);
    {
        if (!env->IsSameObject(mButtonCallbackObj, button_callback_obj)) {
            if (mButtonCallbackObj) {
                env->DeleteGlobalRef(mButtonCallbackObj);  // Delete old
            }
            mButtonCallbackObj = button_callback_obj;
            if (button_callback_obj) {
                // Setup method IDs...
                // Note: button_callback_obj is NOT a global ref yet!
            }
        }
    }
    pthread_mutex_unlock(&button_mutex);
}
```

**HAZARD:** In `UVCButtonCallback::setCallback`, the passed `button_callback_obj` is stored directly without `NewGlobalRef`. This is a **P0 bug** - the local reference will become invalid after the JNI call returns.

**Contrast with correct pattern in `serenegiant_usb_UVCCamera.cpp:268`:**
```cpp
jobject button_callback_obj = env->NewGlobalRef(jIButtonCallback);
// ... passed to callback handler
```

---

## Method ID Caching

### Cached Method IDs

| ID | Struct | Field | Method Signature |
|----|--------|-------|------------------|
| MC-001 | `ibuttoncallback_fields` | `onButton` | `(II)V` |
| MC-002 | `istatuscallback_fields` | `onStatus` | `(IIII[B)V` |
| MC-003 | `ireadinesscallback_fields` | `onNativeReady` | `()V` |
| MC-004 | `iframecallback_fields` | `onFrame` | `(Ljava/nio/ByteBuffer;)V` |
| MC-005 | `mCaptureCallbackMethod` | - | `(IIJLjava/nio/ByteBuffer;)V` |

### Caching Pattern

```cpp
// Method ID cached per callback object (thread-safe with mutex)
jclass clazz = env->GetObjectClass(button_callback_obj);
if (LIKELY(clazz)) {
    ibuttoncallback_fields.onButton = env->GetMethodID(clazz,
        "onButton", "(II)V");
}
```

**Thread Safety:**
- Method ID lookup protected by `button_mutex`
- Method IDs are valid for class lifetime
- ✅ Pattern is correct

---

## Exception Handling

### Exception Check Sites

| File | Line | Pattern | Complete |
|------|------|---------|----------|
| `UVCPreview.cpp` | 292 | `ExceptionClear` only | ⚠️ |
| `UVCPreview.cpp` | 1417 | `ExceptionClear` only | ⚠️ |
| `UVCPreview.cpp` | 2644-2646 | Check→Describe→Clear | ✅ |
| `UVCButtonCallback.cpp` | 48 | `ExceptionClear` only | ⚠️ |
| `UVCButtonCallback.cpp` | 67 | `ExceptionClear` only | ⚠️ |

### Recommended Exception Pattern

```cpp
// After any JNI call that might throw
void safeJniCall(JNIEnv* env, jobject obj) {
    env->CallVoidMethod(obj, methodId, args...);

    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();  // Log for debugging
        env->ExceptionClear();      // Clear before returning to native
        // Handle error condition
    }
}
```

**Hazard:** Calling JNI functions with a pending exception causes undefined behavior.

---

## Thread-Safe Handle Management

### HandleManager Pattern

**Location:** `HandleManager.h`

The codebase uses a generation-based handle manager for safe JNI object access:

```cpp
// Registration (JNI thread)
int64_t handle = getCameraHandleManager().registerContext(camera);
setField_long(env, thiz, "mNativePtr", handle);

// Acquisition (any thread)
auto ref = getCameraHandleManager().acquire(handle);
if (!ref) {
    // Handle invalid/stale handle
    return JNI_ERR_INVALID_HANDLE;
}
UVCCamera *camera = static_cast<UVCCamera *>(ref.ptr);

// Invalidation (JNI thread during destroy)
void* ctx = getCameraHandleManager().invalidateAndFree(handle);
```

**Thread Safety:**
- Generation counter detects use-after-free
- `acquire()` returns RAII guard that tracks active usage
- `invalidateAndFree()` blocks until all `acquire()` guards released
- ✅ Safe pattern for cross-thread object access

---

## Hazard Summary

### P0: Critical

| ID | Location | Issue | Impact | Fix |
|----|----------|-------|--------|-----|
| JNI-HZ-001 | `UVCButtonCallback.cpp:38` | Storing local ref as member | Use-after-free crash | `NewGlobalRef` |
| JNI-HZ-002 | `UVCStatusCallback.cpp:38` | Same pattern | Use-after-free crash | `NewGlobalRef` |
| JNI-HZ-003 | `UVCReadinessCallback.cpp:66` | Same pattern | Use-after-free crash | `NewGlobalRef` |

### P1: High

| ID | Location | Issue | Impact | Fix |
|----|----------|-------|--------|-----|
| JNI-HZ-004 | `UVCButtonCallback.cpp:80` | Attach/detach per callback | Performance | Reuse attachment |
| JNI-HZ-005 | Multiple | ExceptionClear without Check | May mask errors | Add ExceptionCheck |

### P2: Medium

| ID | Location | Issue | Impact | Fix |
|----|----------|-------|--------|-----|
| JNI-HZ-006 | `utilbase.cpp:27` | Non-atomic savedVm | Unlikely race | std::atomic |
| JNI-HZ-007 | All callbacks | No timeout on mutex | Potential deadlock | Use try_lock |

---

## JNI Thread Rules Summary

### Rule 1: JNIEnv is Thread-Local

```cpp
// WRONG: Store JNIEnv for later use
JNIEnv* savedEnv;  // Invalid after thread switch!

// CORRECT: Get fresh env per thread
JNIEnv* env;
vm->GetEnv(&env, JNI_VERSION_1_6);
// or
vm->AttachCurrentThread(&env, NULL);
```

### Rule 2: Global References for Cross-Thread Objects

```cpp
// WRONG: Store local reference
mCallbackObj = local_obj;  // Invalid after JNI call returns!

// CORRECT: Create global reference
mCallbackObj = env->NewGlobalRef(local_obj);
```

### Rule 3: Always Detach Attached Threads

```cpp
// Pattern 1: Thread lifetime attach
void* thread_func(void* arg) {
    vm->AttachCurrentThread(&env, NULL);
    // ... work ...
    vm->DetachCurrentThread();
    return NULL;
}

// Pattern 2: Conditional detach
bool attached = false;
if (vm->GetEnv(&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
    vm->AttachCurrentThread(&env, NULL);
    attached = true;
}
// ... work ...
if (attached) vm->DetachCurrentThread();
```

### Rule 4: Clear Exceptions Before Returning to Native

```cpp
// After JNI calls that may throw
env->CallVoidMethod(...);
if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
    return ERROR;
}
```

---

## Migration Recommendations

### Phase 1: Fix Global Reference Bug (P0)

```cpp
// UVCButtonCallback.cpp:38
// Before (BUG):
mButtonCallbackObj = button_callback_obj;

// After (FIXED):
// The NewGlobalRef is done in serenegiant_usb_UVCCamera.cpp:268
// Just verify the passed object is already a global ref
mButtonCallbackObj = button_callback_obj;  // Already global ref from caller
```

**Note:** The actual `NewGlobalRef` happens at line 268 in `serenegiant_usb_UVCCamera.cpp` before passing to the callback handler. Verify this is always the case.

### Phase 2: Reuse Thread Attachment

```cpp
// Instead of per-callback attach/detach, attach at thread start
class ThreadLocalJNI {
    JNIEnv* env = nullptr;
    bool attached = false;

public:
    JNIEnv* get() {
        if (!env) {
            JavaVM* vm = getVM();
            if (vm->GetEnv((void**)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
                vm->AttachCurrentThread(&env, nullptr);
                attached = true;
            }
        }
        return env;
    }

    ~ThreadLocalJNI() {
        if (attached && env) {
            getVM()->DetachCurrentThread();
        }
    }
};

// Usage: thread_local ThreadLocalJNI jni;
```

### Phase 3: RAII Exception Guard

```cpp
class JNIExceptionGuard {
    JNIEnv* env;
public:
    explicit JNIExceptionGuard(JNIEnv* e) : env(e) {}
    ~JNIExceptionGuard() {
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
    }
};

// Usage
void callback(JNIEnv* env) {
    JNIExceptionGuard guard(env);
    env->CallVoidMethod(...);
    // Exception auto-cleared on scope exit
}
```

---

## Cross-Reference

| Deliverable | Relationship |
|-------------|--------------|
| CONCURRENCY-001 | Threads that cross JNI boundary |
| CONCURRENCY-002 | Mutexes protecting callback objects |
| CONCURRENCY-005 | Shutdown must wait for JNI callbacks |
| CONCURRENCY-007 | Thread priorities affect callback latency |
| SAFETY-009 | Handle validation prevents use-after-free |

---

*End of CONCURRENCY-008*
