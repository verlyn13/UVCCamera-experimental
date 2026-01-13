# SAFETY-006: JNI Memory Boundary Audit

**Audit:** AUDIT-002 Memory Safety Audit
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Summary Statistics

| Category | Count |
|----------|-------|
| **Native JNI Functions (libjpeg-turbo)** | 32 |
| **Native JNI Functions (UVCCamera)** | ~70 |
| **JNI Array Operations** | 30 |
| **JNI Direct Buffer Operations** | 7 |
| **JNI String Operations** | 18 |
| **Critical Array Operations** | 59 |
| **Global References** | 18 |
| **Local Reference Cleanup** | 14 |

---

## JNI Architecture Overview

### Registration Patterns

The codebase uses two JNI patterns:

1. **Static JNI Export (libjpeg-turbo):**
```c
JNIEXPORT jint JNICALL Java_org_libjpegturbo_turbojpeg_TJ_bufSize(...)
```

2. **Dynamic Registration (UVCCamera):**
```cpp
static JNINativeMethod methods[] = {
    { "nativeCreate", "()J", (void *) nativeCreate },
    // ...
};
env->RegisterNatives(clazz, methods, num_methods);
```

---

## Critical JNI Boundary Hazards

### JB-001: Direct Buffer Without Bounds Validation

**Location:** `UVCCamera/UVCPreview.cpp:1415`
**Pattern:**
```cpp
jobject buf = env->NewDirectByteBuffer(callback_frame->data, callbackPixelBytes);
if (LIKELY(buf)) {
    env->CallVoidMethod(mFrameCallbackObj, iframecallback_fields.onFrame, buf);
    env->DeleteLocalRef(buf);
}
```

**Hazards:**
1. Native pointer `callback_frame->data` lifetime must exceed Java usage
2. `callbackPixelBytes` calculated from frame dimensions - overflow risk
3. Java code may hold reference after native buffer freed

**2026 Migration:**
```cpp
// Use AHardwareBuffer shared across JNI boundary
jobject hwBuf = AHardwareBuffer_toHardwareBuffer(env, ahw_buffer);
// HardwareBuffer has reference counting across boundaries
```

---

### JB-002: String Operations Without Null Check

**Locations:** Multiple files
**Pattern:**
```cpp
// UVCCamera/serenegiant_usb_UVCCamera.cpp:172
const char *c_usbfs = env->GetStringUTFChars(usbfs_str, JNI_FALSE);
// ... use c_usbfs ...
env->ReleaseStringUTFChars(usbfs_str, c_usbfs);
```

**Hazards:**
1. `GetStringUTFChars` can return NULL on OOM
2. NULL check missing before use
3. Must release even if string not used

**2026 Migration:**
```cpp
std::optional<std::string_view> getJniString(JNIEnv* env, jstring str) {
    if (!str) return std::nullopt;
    const char* utf = env->GetStringUTFChars(str, nullptr);
    if (!utf) return std::nullopt;
    // RAII wrapper for release
    JniStringGuard guard{env, str, utf};
    return std::string_view{utf};
}
```

---

### JB-003: Critical Array Access Without Null Check

**Location:** `libjpeg-turbo-1.5.0/turbojpeg-jni.c:213`
**Pattern:**
```c
bailif0(srcBuf=(*env)->GetPrimitiveArrayCritical(env, src, 0));
bailif0(jpegBuf=(*env)->GetPrimitiveArrayCritical(env, dst, 0));
// ... process in critical region ...
if(jpegBuf) (*env)->ReleasePrimitiveArrayCritical(env, dst, jpegBuf, 0);
if(srcBuf) (*env)->ReleasePrimitiveArrayCritical(env, src, srcBuf, 0);
```

**Hazards:**
1. `GetPrimitiveArrayCritical` can return NULL
2. Critical region blocks GC - extended processing risks ANR
3. Early return in critical region leaves array pinned

**Mitigations Present:**
- Uses `bailif0` macro for null checks
- Proper release in cleanup path

---

### JB-004: Array Length Validation

**Location:** `libjpeg-turbo-1.5.0/turbojpeg-jni.c:207`
**Pattern:**
```c
if((*env)->GetArrayLength(env, src)*srcElementSize<arraySize)
    _throwarg("Source buffer is not large enough");
```

**Good Practice:** libjpeg-turbo validates array lengths before access.

**Missing in UVCCamera:** Direct buffer operations don't validate size.

---

### JB-005: Global Reference Lifecycle

**Locations:** Multiple callback handlers
**Pattern:**
```cpp
// Creation (serenegiant_usb_UVCCamera.cpp:253)
jobject status_callback_obj = env->NewGlobalRef(jIStatusCallback);

// Release (UVCStatusCallback.cpp:36)
env->DeleteGlobalRef(mStatusCallbackObj);
```

**Hazards:**
1. Global refs are roots - prevent GC of Java object
2. Must delete before native object destruction
3. Leak if native exception thrown before cleanup

**Current State:**
| Callback Type | Create Site | Delete Site | Lifecycle |
|---------------|-------------|-------------|-----------|
| Status | serenegiant_usb_UVCCamera.cpp:253 | UVCStatusCallback.cpp:36 | Good |
| Button | serenegiant_usb_UVCCamera.cpp:268 | UVCButtonCallback.cpp:36 | Good |
| Readiness | serenegiant_usb_UVCCamera.cpp:283 | UVCReadinessCallback.cpp:65 | Good |
| Frame | serenegiant_usb_UVCCamera.cpp:436 | UVCPreview.cpp:280 | Good |
| Capture | UVCPreview.cpp:2251 | UVCPreview.cpp:2244 | Good |
| CallbackPipeline | CallbackPipeline.cpp:251 | CallbackPipeline.cpp:60 | Good |

---

### JB-006: Local Reference Table Overflow Risk

**Location:** `UVCPreview.cpp` frame callback loop
**Pattern:**
```cpp
// Called for each frame (30-60 fps)
jobject buf = env->NewDirectByteBuffer(callback_frame->data, callbackPixelBytes);
// ...
env->DeleteLocalRef(buf);
```

**Hazards:**
1. Local ref table has finite capacity (~512 slots)
2. Failure to delete causes table overflow
3. Overflow triggers JNI exception

**Current State:** Properly deletes local refs - Good

---

### JB-007: Handle Manager Pattern (Modern)

**Location:** `UVCCamera/serenegiant_usb_UVCCamera.cpp:123-150`
**Pattern:**
```cpp
static ID_TYPE nativeCreate(JNIEnv *env, jobject thiz) {
    UVCCamera *camera = new UVCCamera();
    int64_t handle = getCameraHandleManager().registerContext(camera);
    if (handle == INVALID_HANDLE) {
        delete camera;
        RETURN(0, ID_TYPE);
    }
    setField_long(env, thiz, "mNativePtr", handle);
    RETURN(handle, ID_TYPE);
}

static void nativeDestroy(JNIEnv *env, jobject thiz, ID_TYPE id_camera) {
    setField_long(env, thiz, "mNativePtr", 0);
    void* ctx = getCameraHandleManager().invalidateAndFree(id_camera);
    if (ctx) {
        UVCCamera *camera = static_cast<UVCCamera *>(ctx);
        SAFE_DELETE(camera);
    }
}
```

**Good Practice:** Uses HandleManager with generation encoding to prevent use-after-free and stale handle attacks.

---

## JNI String Operations Inventory

| File | Get | Release | Create | Status |
|------|-----|---------|--------|--------|
| serenegiant_usb_UVCCamera.cpp | 3 | 2 | 1 | Review |
| SQLiteBufferedPipeline.cpp | 1 | 1 | 0 | Good |
| PublisherPipeline.cpp | 2 | 2 | 0 | Good |
| FrameBufferJNI.cpp | 2 | 2 | 0 | Good |
| turbojpeg-jni.c | 1 | 1 | 1 | Good |

### Unbalanced String Operations

**serenegiant_usb_UVCCamera.cpp:212-222:**
```cpp
const char *path = env->GetStringUTFChars(usbfs_str, JNI_FALSE);
// ... strdup(path) ...
env->ReleaseStringUTFChars(usbfs_str, path);
```
**Note:** `strdup` creates owned copy - proper pattern

---

## JNI Direct Buffer Sites

| Location | Size Source | Lifetime | Risk |
|----------|-------------|----------|------|
| FrameBufferJNI.cpp:759 | Telemetry struct | Static | Low |
| CallbackPipeline.cpp:154 | `callbackPixelBytes` | Frame duration | Medium |
| UVCStatusCallback.cpp:66 | `data_len` | Callback duration | Medium |
| UVCPreview.cpp:1415 | `callbackPixelBytes` | Frame duration | Medium |
| UVCPreview.cpp:2635 | `bufferSize` | Capture duration | Medium |
| turbojpeg-jni.c:988 | Coefficient size | Decompression | Low |

---

## JNI Array Operations by Risk Level

### High Risk (No Bounds Check Before Access)

None found - libjpeg-turbo validates all array accesses.

### Medium Risk (Calculated Sizes)

| Location | Calculation |
|----------|-------------|
| turbojpeg-jni.c:207 | `GetArrayLength(env, src)*srcElementSize<arraySize` |
| turbojpeg-jni.c:333 | `GetArrayLength(env, jSrcPlanes[i])<srcOffsets[i]+planeSize` |

### Low Risk (Well Validated)

- All 30 array operations in libjpeg-turbo use `GetArrayLength` validation

---

## 2026 Migration Recommendations

### Phase 1: RAII JNI Wrappers

```cpp
// JNI String RAII wrapper
class JniString {
    JNIEnv* env_;
    jstring str_;
    const char* utf_;
public:
    JniString(JNIEnv* env, jstring str)
        : env_(env), str_(str), utf_(env->GetStringUTFChars(str, nullptr)) {}
    ~JniString() { if (utf_) env_->ReleaseStringUTFChars(str_, utf_); }

    explicit operator bool() const { return utf_ != nullptr; }
    const char* c_str() const { return utf_; }
    std::string_view view() const { return utf_ ? std::string_view{utf_} : ""; }
};

// JNI Local Ref RAII wrapper
template<typename T>
class JniLocalRef {
    JNIEnv* env_;
    T ref_;
public:
    JniLocalRef(JNIEnv* env, T ref) : env_(env), ref_(ref) {}
    ~JniLocalRef() { if (ref_) env_->DeleteLocalRef(ref_); }
    T get() const { return ref_; }
    T release() { return std::exchange(ref_, nullptr); }
};

// JNI Critical Array RAII wrapper
class JniCriticalArray {
    JNIEnv* env_;
    jarray arr_;
    void* ptr_;
public:
    JniCriticalArray(JNIEnv* env, jarray arr)
        : env_(env), arr_(arr), ptr_(env->GetPrimitiveArrayCritical(arr, nullptr)) {}
    ~JniCriticalArray() { if (ptr_) env_->ReleasePrimitiveArrayCritical(arr_, ptr_, 0); }

    explicit operator bool() const { return ptr_ != nullptr; }
    void* get() const { return ptr_; }
};
```

### Phase 2: Replace Direct Buffers with AHardwareBuffer

```cpp
// Current (hazardous)
jobject buf = env->NewDirectByteBuffer(callback_frame->data, size);

// 2026 (safe)
AHardwareBuffer* ahwBuffer = ring_buffer->acquireForJava();
jobject hwBuffer = AHardwareBuffer_toHardwareBuffer(env, ahwBuffer);
// Java side uses HardwareBuffer API - proper synchronization guaranteed
```

### Phase 3: JNI Exception Handling

```cpp
// Macro for exception-safe JNI calls
#define JNI_CHECK_EXCEPTION(env) \
    do { \
        if (env->ExceptionCheck()) { \
            env->ExceptionDescribe(); \
            env->ExceptionClear(); \
            return std::unexpected(JniError::Exception); \
        } \
    } while(0)

// Usage
std::expected<void, JniError> callJavaMethod(JNIEnv* env, jobject obj, jmethodID method) {
    env->CallVoidMethod(obj, method);
    JNI_CHECK_EXCEPTION(env);
    return {};
}
```

---

## Critical Path Analysis

### Frame Delivery Path (Hot Path)

```
USB Transfer (libusb)
  ↓
frame_callback (UVCPreview.cpp)
  ↓
NewDirectByteBuffer  ← JNI allocation
  ↓
CallVoidMethod  ← Cross JNI boundary
  ↓
DeleteLocalRef  ← JNI cleanup
```

**Timing Budget:** < 33ms for 30fps, < 16ms for 60fps
**JNI Overhead:** ~1-5us per call

### Recommended Optimization

Replace per-frame JNI buffer creation with ring buffer approach:
1. Pre-allocate AHardwareBuffer ring
2. Map once, share across JNI boundary
3. Use fence-based synchronization (no JNI calls in hot path)

---

## Hazard Summary

| ID | Hazard | Severity | Files | Status |
|----|--------|----------|-------|--------|
| JB-001 | Direct buffer lifetime | High | UVCPreview.cpp | Migrate to HWBuffer |
| JB-002 | String null check | Medium | Multiple | Add validation |
| JB-003 | Critical array access | Low | turbojpeg-jni.c | Already validated |
| JB-004 | Array bounds | Low | turbojpeg-jni.c | Good practice |
| JB-005 | Global ref lifecycle | Medium | Callbacks | Properly managed |
| JB-006 | Local ref overflow | Low | UVCPreview.cpp | Properly cleaned |
| JB-007 | Handle validation | Low | HandleManager | Modern pattern |

---

## Migration Priority

### Phase 1 (Immediate)
1. Add null checks to string operations
2. Implement RAII JNI wrappers

### Phase 2 (Near-term)
1. Replace DirectByteBuffer with AHardwareBuffer for frame callbacks
2. Add exception checking to all JNI calls

### Phase 3 (Long-term)
1. Zero-copy frame delivery via shared memory
2. Remove per-frame JNI allocations from hot path

---

*End of SAFETY-006*
