# JNI-001: Legacy JNI Function Inventory

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** Complete inventory of native method registrations
**Status:** Complete

---

## Summary

| Metric | Value |
|--------|-------|
| Total JNI Methods | **160** |
| Registration Points | 3 |
| JNI Source Files | 3 |
| Lines of JNI Code | ~4,400 |

---

## 1. Registration Points

| Class | File | Methods | Purpose |
|-------|------|---------|---------|
| `com/serenegiant/usb/UVCCamera` | serenegiant_usb_UVCCamera.cpp | 121 | Core camera control |
| `com/scopecam/camera/buffer/FrameBufferManager` | FrameBufferJNI.cpp | 33 | Zero-copy frame buffer |
| `com/scopecam/camera/egl/EGLImageHelper` | EGLImageHelperJNI.cpp | 6 | EGL zero-copy pipeline |

---

## 2. Method Categories

### 2.1 serenegiant_usb_UVCCamera.cpp (121 methods)

| Category | Count | Description |
|----------|-------|-------------|
| Core Lifecycle | 2 | nativeCreate, nativeDestroy |
| Connection | 2 | nativeConnect, nativeConnectSimple |
| Release | 1 | nativeRelease |
| Callbacks | 4 | Status, Button, Readiness, IsReady |
| Cleanup | 3 | nativeCleanup, ReleaseInterface, HardReset |
| Preview Setup | 5 | SupportedSize, PreviewSize, Start/Stop, Display |
| Frame/Capture | 2 | FrameCallback, CaptureDisplay |
| State Machine (Phase 2) | 4 | WARM state support |
| Ring Buffer (Phase 4) | 7 | Decoupled frame streaming |
| OutputMode | 2 | Frame routing control |
| Telemetry | 5 | Drop counters, surface/USB status |
| Capture Callback | 8 | Dual-emit architecture |
| Control Supports | 2 | CT/PU capability query |
| Camera Controls | 81 | 27 controls x 3 (Update/Set/Get) |

### 2.2 FrameBufferJNI.cpp (33 methods)

| Category | Count | Description |
|----------|-------|-------------|
| Lifecycle | 2 | Allocate, Destroy |
| Consumer API | 2 | AcquireBuffer, ReleaseBuffer |
| Fence API | 3 | Bidirectional GPU sync |
| State Queries | 3 | Allocated, Width, Height |
| Telemetry - Basic | 4 | Frames received/rendered/dropped/corrupted |
| Telemetry - Ring | 3 | Producer stalls, Consumer starves |
| Telemetry - Timing | 3 | Decode time, Fence wait |
| Telemetry - Errors | 2 | Error recording |
| Telemetry - Stream | 4 | Protocol, Negotiation, Fallback |
| Telemetry - USB | 6 | Packets, Overflow, Timeout |
| ByteBuffer | 1 | Efficient packed transfer |
| Snapshot | 1 | Capture to FD |

### 2.3 EGLImageHelperJNI.cpp (6 methods)

| Category | Count | Description |
|----------|-------|-------------|
| EGL Zero-Copy | 6 | HardwareBuffer→EGLImage pipeline |

---

## 3. Handle Pattern Analysis

### 3.1 Modern HandleManager Usage (MTE-Safe)

All three JNI files use the modern HandleManager pattern:

```cpp
// Pattern: ScopedRef acquisition with validation
auto ref = getCameraHandleManager().acquire(id_camera);
if (!ref) {
    RETURN(JNI_ERR_INVALID_HANDLE, jint);
}
UVCCamera *camera = static_cast<UVCCamera *>(ref.ptr);
```

**Evidence:**
- `serenegiant_usb_UVCCamera.cpp`: 100% of methods use HandleManager
- `FrameBufferJNI.cpp`: Uses `acquireRingBuffer()` helper with magic validation
- `EGLImageHelperJNI.cpp`: Uses `reinterpret_cast<jlong>` for EGL handles (legacy pattern)

### 3.2 Handle Types

| Handle Type | Manager | Usage |
|-------------|---------|-------|
| Camera Handle | `getCameraHandleManager()` | All UVCCamera methods |
| RingBuffer Handle | `getRingBufferHandleManager()` | FrameBuffer methods |
| EGLImage Handle | Direct cast (legacy) | EGL methods |

---

## 4. Method Signatures

### 4.1 Core Methods (High Importance)

| Method | Signature | Return |
|--------|-----------|--------|
| `nativeCreate` | `()J` | jlong (handle) |
| `nativeDestroy` | `(J)V` | void |
| `nativeConnect` | `(JIIIIILjava/lang/String;)I` | jint |
| `nativeConnectSimple` | `(JILjava/lang/String;)I` | jint |
| `nativeStartPreview` | `(J)I` | jint |
| `nativeStopPreview` | `(J)I` | jint |
| `nativeSetPreviewDisplay` | `(JLandroid/view/Surface;)I` | jint |
| `nativeSetOutputMode` | `(JI)I` | jint |

### 4.2 Frame Buffer Methods (Zero-Copy Path)

| Method | Signature | Return |
|--------|-----------|--------|
| `nativeFrameBufferAllocate` | `(III)J` | jlong (handle) |
| `nativeFrameBufferDestroy` | `(J)V` | void |
| `nativeFrameBufferAcquireBuffer` | `(J)Landroid/hardware/HardwareBuffer;` | HardwareBuffer |
| `nativeFrameBufferReleaseBuffer` | `(J)V` | void |
| `nativeFrameBufferGetAcquireFence` | `(J)I` | jint (FD) |
| `nativeFrameBufferReleaseWithFence` | `(JJI)V` | void |

### 4.3 EGL Methods (GPU Integration)

| Method | Signature | Return |
|--------|-----------|--------|
| `nativeCreateEGLImageFromHardwareBuffer` | `(EGLDisplay;HardwareBuffer;)J` | jlong |
| `nativeDestroyEGLImage` | `(EGLDisplay;J)V` | void |
| `nativeGlEGLImageTargetTexture2DOES` | `(IJ)V` | void |
| `nativeImportNativeFence` | `(EGLDisplay;I)J` | jlong |
| `nativeCreateReleaseFence` | `(EGLDisplay;)I` | jint (FD) |

---

## 5. JNI Architecture Assessment

### 5.1 Strengths (Modern Patterns)

| Pattern | Evidence | Status |
|---------|----------|--------|
| HandleManager | ScopedRef acquisition | Implemented |
| Magic Validation | `validateMagic()` checks | Implemented |
| Zero-Copy Path | AHardwareBuffer support | Implemented |
| Fence Sync | Bidirectional GPU fencing | Implemented |
| OutputMode | Single source of truth for routing | Implemented |
| Telemetry | Comprehensive instrumentation | Implemented |

### 5.2 Gaps Identified

| Gap | Severity | Location |
|-----|----------|----------|
| EGL handle casting | Medium | EGLImageHelperJNI.cpp |
| No JNI exception propagation | Low | All files use return codes |
| Camera control boilerplate | Info | 81 repetitive methods |

### 5.3 Method Registration Pattern

All files use dynamic registration via `RegisterNatives`:

```cpp
jint registerNativeMethods(JNIEnv* env, const char *class_name,
                          JNINativeMethod *methods, int num_methods);
```

**Advantages:**
- No symbol naming conventions required
- Faster lookup than JNI_OnLoad discovery
- Better obfuscation compatibility

---

## 6. Camera Control Methods

### 6.1 Terminal Controls (CT)

| Control | Update | Set | Get |
|---------|--------|-----|-----|
| ScanningMode | nativeUpdateScanningModeLimit | nativeSetScanningMode | nativeGetScanningMode |
| ExposureMode | nativeUpdateExposureModeLimit | nativeSetExposureMode | nativeGetExposureMode |
| ExposurePriority | nativeUpdateExposurePriorityLimit | nativeSetExposurePriority | nativeGetExposurePriority |
| Exposure | nativeUpdateExposureLimit | nativeSetExposure | nativeGetExposure |
| ExposureRel | nativeUpdateExposureRelLimit | nativeSetExposureRel | nativeGetExposureRel |
| AutoFocus | nativeUpdateAutoFocusLimit | nativeSetAutoFocus | nativeGetAutoFocus |
| Focus | nativeUpdateFocusLimit | nativeSetFocus | nativeGetFocus |
| FocusRel | nativeUpdateFocusRelLimit | nativeSetFocusRel | nativeGetFocusRel |
| Iris | nativeUpdateIrisLimit | nativeSetIris | nativeGetIris |
| IrisRel | nativeUpdateIrisRelLimit | nativeSetIrisRel | nativeGetIrisRel |
| Pan | nativeUpdatePanLimit | nativeSetPan | nativeGetPan |
| Tilt | nativeUpdateTiltLimit | nativeSetTilt | nativeGetTilt |
| Roll | nativeUpdateRollLimit | nativeSetRoll | nativeGetRoll |
| PanRel | nativeUpdatePanRelLimit | nativeSetPanRel | nativeGetPanRel |
| TiltRel | nativeUpdateTiltRelLimit | nativeSetTiltRel | nativeGetTiltRel |
| RollRel | nativeUpdateRollRelLimit | nativeSetRollRel | nativeGetRollRel |

### 6.2 Processing Unit Controls (PU)

| Control | Update | Set | Get |
|---------|--------|-----|-----|
| AutoWhiteBalance | nativeUpdateAutoWhiteBlanceLimit | nativeSetAutoWhiteBlance | nativeGetAutoWhiteBlance |
| AutoWhiteBalanceCompo | nativeUpdateAutoWhiteBlanceCompoLimit | nativeSetAutoWhiteBlanceCompo | nativeGetAutoWhiteBlanceCompo |
| WhiteBalance | nativeUpdateWhiteBlanceLimit | nativeSetWhiteBlance | nativeGetWhiteBlance |
| WhiteBalanceCompo | nativeUpdateWhiteBlanceCompoLimit | nativeSetWhiteBlanceCompo | nativeGetWhiteBlanceCompo |
| BacklightComp | nativeUpdateBacklightCompLimit | nativeSetBacklightComp | nativeGetBacklightComp |
| Brightness | nativeUpdateBrightnessLimit | nativeSetBrightness | nativeGetBrightness |
| Contrast | nativeUpdateContrastLimit | nativeSetContrast | nativeGetContrast |
| AutoContrast | nativeUpdateAutoContrastLimit | nativeSetAutoContrast | nativeGetAutoContrast |
| Sharpness | nativeUpdateSharpnessLimit | nativeSetSharpness | nativeGetSharpness |
| Gain | nativeUpdateGainLimit | nativeSetGain | nativeGetGain |
| Gamma | nativeUpdateGammaLimit | nativeSetGamma | nativeGetGamma |
| Saturation | nativeUpdateSaturationLimit | nativeSetSaturation | nativeGetSaturation |
| Hue | nativeUpdateHueLimit | nativeSetHue | nativeGetHue |
| AutoHue | nativeUpdateAutoHueLimit | nativeSetAutoHue | nativeGetAutoHue |
| PowerlineFrequency | nativeUpdatePowerlineFrequencyLimit | nativeSetPowerlineFrequency | nativeGetPowerlineFrequency |
| Zoom | nativeUpdateZoomLimit | nativeSetZoom | nativeGetZoom |
| ZoomRel | nativeUpdateZoomRelLimit | nativeSetZoomRel | nativeGetZoomRel |
| DigitalMultiplier | nativeUpdateDigitalMultiplierLimit | nativeSetDigitalMultiplier | nativeGetDigitalMultiplier |
| DigitalMultiplierLimit | nativeUpdateDigitalMultiplierLimitLimit | nativeSetDigitalMultiplierLimit | nativeGetDigitalMultiplierLimit |
| AnalogVideoStandard | nativeUpdateAnalogVideoStandardLimit | nativeSetAnalogVideoStandard | nativeGetAnalogVideoStandard |
| AnalogVideoLockState | nativeUpdateAnalogVideoLockStateLimit | nativeSetAnalogVideoLoackState | nativeGetAnalogVideoLoackState |
| Privacy | nativeUpdatePrivacyLimit | nativeSetPrivacy | nativeGetPrivacy |

---

## 7. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| JNI-001-001 | Info | 160 JNI methods total | Well-organized |
| JNI-001-002 | Info | HandleManager used consistently | Keep pattern |
| JNI-001-003 | Medium | EGL handles use direct cast | Migrate to HandleManager |
| JNI-001-004 | Info | 81 camera control methods | Consider codegen |
| JNI-001-005 | Low | "WhiteBlance" typo preserved | Legacy compatibility |
| JNI-001-006 | Info | Zero-copy path implemented | Phase 4 complete |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-003** | Handle leak analysis (AUDIT-004) |
| **ARCH-001** | Architectural decisions |
| **FrameBufferJNI.cpp:123** | Modern HandleManager pattern |
| **EGLImageHelperJNI.cpp:282** | Legacy jlong cast |

---

## Raw Data

| File | Location |
|------|----------|
| UVCCamera methods | `raw/jni/uvccamera-methods.txt` |
| FrameBuffer methods | `raw/jni/framebuffer-methods.txt` |
| EGLImageHelper methods | `raw/jni/eglimagehelper-methods.txt` |

---

*End of JNI-001*
