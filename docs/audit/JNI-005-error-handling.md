# JNI-005: Error Handling Assessment

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** JNI error handling patterns
**Status:** Complete

---

## Summary

| Metric | Value |
|--------|-------|
| Error Codes | 2 main types |
| ExceptionClear Calls | 22 |
| Handle Validation | 100% of methods |
| Exception Throwing | Not used (return codes) |

---

## 1. Error Code Pattern

### 1.1 Return Code Strategy

The codebase uses **return codes** instead of JNI exceptions:

```cpp
// HandleManager.h:64
static constexpr int JNI_ERR_INVALID_HANDLE = -100;

// Standard pattern in all JNI methods
auto ref = getCameraHandleManager().acquire(id_camera);
if (!ref) {
    RETURN(JNI_ERR_INVALID_HANDLE, jint);  // -100
}
```

### 1.2 Error Code Table

| Code | Constant | Meaning |
|------|----------|---------|
| 0 | Success | Operation completed |
| -1 | JNI_ERR | General error |
| -2 | - | Validation error |
| -100 | JNI_ERR_INVALID_HANDLE | Handle validation failed |
| Other | libuvc codes | USB/UVC errors |

### 1.3 Error Propagation

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    ERROR PROPAGATION FLOW                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Kotlin                  JNI                      Native                 │
│    │                      │                         │                    │
│    │  nativeXxx()         │                         │                    │
│    ├─────────────────────►│                         │                    │
│    │                      │  acquire(handle)        │                    │
│    │                      ├────────────────────────►│                    │
│    │                      │                         │                    │
│    │                      │  ◄── null ref           │                    │
│    │                      │                         │                    │
│    │  ◄───────────────────┤  return -100            │                    │
│    │                      │                         │                    │
│    │  if (result < 0) {   │                         │                    │
│    │    handleError()     │                         │                    │
│    │  }                   │                         │                    │
│    │                      │                         │                    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Exception Handling

### 2.1 ExceptionClear Usage

The code clears exceptions from failed JNI lookups:

```cpp
// serenegiant_usb_UVCCamera.cpp:100
jfieldID id = env->GetFieldID(clazz, field_name, "I");
if (LIKELY(id))
    env->SetIntField(java_obj, id, val);
else {
    LOGE("__setField_int:field '%s' not found", field_name);
    env->ExceptionClear();  // Clear NoSuchFieldError
}
```

### 2.2 ExceptionClear Locations

| File | Line | Context |
|------|------|---------|
| serenegiant_usb_UVCCamera.cpp | 100 | Field lookup failure |
| UVCPreview.cpp | 292 | Method lookup failure |
| UVCPreview.cpp | 1417 | Callback invocation |
| UVCPreview.cpp | 2644-2646 | Capture callback |
| UVCButtonCallback.cpp | 48, 67 | Button callback |
| UVCStatusCallback.cpp | 48, 68 | Status callback |
| UVCReadinessCallback.cpp | 77, 104 | Readiness callback |
| EGLImageHelperJNI.cpp | 538 | Class lookup |
| FrameBufferJNI.cpp | 766, 883 | Class registration |
| CallbackPipeline.cpp | 72, 156 | Method lookup |

### 2.3 Pattern: Safe Callback Invocation

```cpp
// UVCPreview.cpp:1416-1417
env->CallVoidMethod(mFrameCallbackObj, iframecallback_fields.onFrame, buf);
env->ExceptionClear();  // Always clear after callback - prevents cascade
```

---

## 3. Handle Validation Pattern

### 3.1 Consistent Validation

100% of JNI methods validate handles before use:

```cpp
static jint nativeXxx(JNIEnv *env, jobject thiz, ID_TYPE id_camera, ...) {
    ENTER();
    auto ref = getCameraHandleManager().acquire(id_camera);
    if (!ref) {
        RETURN(JNI_ERR_INVALID_HANDLE, jint);  // ← Every method
    }
    UVCCamera *camera = static_cast<UVCCamera *>(ref.ptr);
    // ... proceed with operation
}
```

### 3.2 Validation Statistics

| File | Validation Checks |
|------|------------------|
| serenegiant_usb_UVCCamera.cpp | 121 |
| FrameBufferJNI.cpp | 33 |
| Total | 154+ |

---

## 4. Gaps and Recommendations

### 4.1 Current State

| Aspect | Status |
|--------|--------|
| Return codes | Consistent |
| Handle validation | 100% |
| Exception clearing | Implemented |
| Error logging | LOGE macros |

### 4.2 Future Enhancement (Optional)

For 2026 architecture, consider `std::expected` mapping:

```cpp
// Future pattern (C++23)
std::expected<jint, UvcError> nativeXxx(...) {
    auto ref = getCameraHandleManager().acquire(id_camera);
    if (!ref) {
        return std::unexpected(UvcError::InvalidHandle);
    }
    // ...
}

// JNI bridge converts to exception
jint nativeXxx_wrapper(JNIEnv *env, ...) {
    auto result = nativeXxx(...);
    if (!result) {
        throwJniException(env, result.error());
        return -1;
    }
    return *result;
}
```

---

## 5. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| JNI-005-001 | Info | Return codes used consistently | Document error codes |
| JNI-005-002 | Info | ExceptionClear after callbacks | Prevents cascades |
| JNI-005-003 | Info | Handle validation 100% | Robust |
| JNI-005-004 | Low | No JNI exceptions thrown | Consider for critical errors |
| JNI-005-005 | Info | LOGE for all failures | Good observability |

---

## 6. Cross-Reference

| Document | Relationship |
|----------|--------------|
| **HandleManager.h:64** | JNI_ERR_INVALID_HANDLE definition |
| **JNI-002** | Handle validation |
| **JNI-004** | Cleanup error handling |

---

*End of JNI-005*
