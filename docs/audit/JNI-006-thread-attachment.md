# JNI-006: Thread Attachment Analysis

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** JNI thread attachment patterns
**Status:** Complete

---

## Summary

| Metric | Value |
|--------|-------|
| Native Threads | 4+ types |
| Thread Attach Locations | 7 |
| Attach/Detach Pairs | Properly matched |
| Leak Risk | Low |

---

## 1. Thread Model

### 1.1 Thread Types

| Thread | Purpose | JNI Env | Attachment |
|--------|---------|---------|------------|
| Main UI | Kotlin calls | Provided | Native |
| Preview | Frame conversion | Needed | Manual |
| Capture | Photo processing | Needed | Manual |
| Callback | Java callbacks | Needed | Manual |

### 1.2 Thread Attachment Pattern

```cpp
// Pattern: Attach, use, detach in callbacks
JavaVM *vm = getVM();
JNIEnv *env = NULL;
bool attached = false;

if (vm->GetEnv((void **)&env, JNI_VERSION_1_6) != JNI_OK) {
    if (vm->AttachCurrentThread(&env, NULL) == JNI_OK) {
        attached = true;
    } else {
        LOGE("Failed to attach thread");
        return;
    }
}

// Use env for JNI calls...
env->CallVoidMethod(callback, method, args...);

// Cleanup
if (attached) {
    vm->DetachCurrentThread();
}
```

---

## 2. Attachment Locations

### 2.1 UVCPreview.cpp

| Line | Function | Purpose |
|------|----------|---------|
| 1309 | do_preview | Frame callback delivery |
| 2588 | capture callback | Capture frame delivery |

```cpp
// UVCPreview.cpp:1309
vm->AttachCurrentThread(&env, NULL);
// ... callback invocation
vm->DetachCurrentThread();  // Line 1312
```

### 2.2 Callback Files

| File | Lines | Purpose |
|------|-------|---------|
| UVCButtonCallback.cpp | 80, 84 | Button press callback |
| UVCStatusCallback.cpp | 82, 86 | Status change callback |
| UVCReadinessCallback.cpp | 98, 109 | Readiness notification |
| CaptureBasePipeline.cpp | 172, 175 | Pipeline callbacks |

---

## 3. Thread Attachment Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THREAD ATTACHMENT LIFECYCLE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Native Thread (not attached to JVM)                                         │
│       │                                                                      │
│       │  Need to call Java callback                                          │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────┐                         │
│  │ vm->GetEnv(&env, JNI_VERSION_1_6)              │                         │
│  │   Returns: JNI_OK (already attached)            │                         │
│  │   Returns: JNI_EDETACHED (need attach)          │                         │
│  └──────────────────────┬──────────────────────────┘                         │
│                         │                                                    │
│            ┌────────────┴────────────┐                                       │
│            │                         │                                       │
│       JNI_OK                    JNI_EDETACHED                                │
│       (use env)                      │                                       │
│            │                         ▼                                       │
│            │        ┌─────────────────────────────────────┐                  │
│            │        │ vm->AttachCurrentThread(&env, NULL) │                  │
│            │        │ attached = true                      │                  │
│            │        └──────────────────┬──────────────────┘                  │
│            │                           │                                     │
│            └───────────┬───────────────┘                                     │
│                        │                                                     │
│                        ▼                                                     │
│  ┌─────────────────────────────────────────────────┐                         │
│  │ env->CallVoidMethod(callback, method, ...)     │                         │
│  │ env->ExceptionClear()  // Always after callback │                         │
│  └──────────────────────┬──────────────────────────┘                         │
│                         │                                                    │
│                         ▼                                                    │
│  ┌─────────────────────────────────────────────────┐                         │
│  │ if (attached) vm->DetachCurrentThread()         │                         │
│  └─────────────────────────────────────────────────┘                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. getEnv Helper

### 4.1 Implementation

```cpp
// utilbase.cpp:37
JNIEnv *getEnv() {
    JNIEnv *env = NULL;
    JavaVM *vm = getVM();
    if (vm && vm->GetEnv((void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        // Thread not attached - caller must attach if needed
        env = NULL;
    }
    return env;
}
```

### 4.2 Usage Pattern

```cpp
JNIEnv *env = getEnv();
if (!env) {
    // Thread not attached, need manual attach for callbacks
    vm->AttachCurrentThread(&env, NULL);
    // ...use env...
    vm->DetachCurrentThread();
}
```

---

## 5. Thread Safety Considerations

### 5.1 GlobalRef Access

GlobalRefs are thread-safe:
```cpp
// Stored in class member, used from any thread
jobject mFrameCallbackObj;  // GlobalRef - JVM managed

// Safe to call from native thread after attach
env->CallVoidMethod(mFrameCallbackObj, method, args);
```

### 5.2 LocalRef Scope

LocalRefs are NOT thread-safe - must be converted:
```cpp
// WRONG: LocalRef from one thread used in another
jobject localRef = env->NewLocalRef(obj);  // Thread A
// ... pass to Thread B - INVALID!

// CORRECT: Convert to GlobalRef
jobject globalRef = env->NewGlobalRef(localRef);
// globalRef safe to use from any thread
```

---

## 6. Potential Issues

### 6.1 Attach Without Detach

All attachment points properly detach:
```cpp
// Pattern verified in all locations
vm->AttachCurrentThread(&env, NULL);
// ... work
vm->DetachCurrentThread();  // Always called
```

### 6.2 Thread Name Setting (Optional Enhancement)

```cpp
// Current: Anonymous native thread
vm->AttachCurrentThread(&env, NULL);

// Improved: Named thread for debugging
JavaVMAttachArgs args = {
    JNI_VERSION_1_6,
    "UVCCamera-Preview",  // Thread name
    NULL
};
vm->AttachCurrentThreadAsDaemon(&env, &args);
```

---

## 7. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| JNI-006-001 | Info | All attach/detach properly paired | No leaks |
| JNI-006-002 | Info | GlobalRefs used for cross-thread | Thread-safe |
| JNI-006-003 | Low | Threads unnamed | Consider naming for debug |
| JNI-006-004 | Info | ExceptionClear after callbacks | Prevents cascade |
| JNI-006-005 | Info | getEnv helper available | Consistent pattern |

---

## 8. Cross-Reference

| Document | Relationship |
|----------|--------------|
| **utilbase.cpp:37** | getEnv() helper |
| **UVCPreview.cpp** | Main thread attachment |
| **JNI-004** | Lifecycle callbacks |
| **JNI-005** | Exception handling |

---

*End of JNI-006*
