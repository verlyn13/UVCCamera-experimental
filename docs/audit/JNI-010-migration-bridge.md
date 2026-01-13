# JNI-010: Migration Bridge Design

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** Legacy to modern JNI transition strategy
**Status:** Design Complete

---

## Summary

| Metric | Value |
|--------|-------|
| Migration Strategy | Parallel Operation |
| Legacy API | Maintained |
| Modern API | Active |
| Breaking Changes | None |

---

## 1. Current State

### 1.1 Coexisting APIs

The codebase already implements parallel API support:

| Feature | Legacy API | Modern API |
|---------|------------|------------|
| Frame delivery | IFrameCallback (ByteBuffer) | AHardwareBuffer ring |
| Window binding | nativeSetPreviewDisplay | nativeSetOutputMode |
| Handle management | Direct pointer cast | HandleManager |

### 1.2 OutputMode Bridge

```cpp
// Single source of truth for routing
enum class OutputMode {
    IDLE = 0,           // Legacy: frames dropped
    DIRECT_WINDOW = 1,  // Legacy: ANativeWindow
    RING_BUFFER = 2     // Modern: AHardwareBuffer
};
```

---

## 2. Migration Path

### 2.1 Phase 1: Parallel Operation (Current)

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CURRENT: PARALLEL OPERATION                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Legacy Client                     Modern Client                     │
│       │                                 │                            │
│       │ nativeSetPreviewDisplay         │ nativeSetOutputMode        │
│       │ nativeSetFrameCallback          │ nativeFrameBufferAllocate  │
│       │                                 │ nativeFrameBufferAcquire   │
│       │                                 │                            │
│       ▼                                 ▼                            │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                     NATIVE LAYER                              │   │
│  │                                                               │   │
│  │  OutputMode switch determines routing:                        │   │
│  │  - DIRECT_WINDOW → ANativeWindow path                        │   │
│  │  - RING_BUFFER → AHardwareBuffer path                        │   │
│  │                                                               │   │
│  │  Both paths share:                                           │   │
│  │  - HandleManager                                             │   │
│  │  - MJPEG decode                                              │   │
│  │  - USB streaming                                             │   │
│  │                                                               │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 Phase 2: Deprecation Warnings (Future)

```kotlin
// Kotlin side
@Deprecated(
    message = "Use OutputMode.RING_BUFFER with FrameBufferManager instead",
    replaceWith = ReplaceWith("setOutputMode(OutputMode.RING_BUFFER)")
)
fun setPreviewDisplay(surface: Surface): Int {
    return nativeSetPreviewDisplay(nativePtr, surface)
}
```

### 2.3 Phase 3: Removal (Future)

Legacy methods removed from:
- JNINativeMethod array
- Java/Kotlin declarations
- Documentation

---

## 3. Compatibility Matrix

### 3.1 API Equivalents

| Legacy | Modern | Notes |
|--------|--------|-------|
| `nativeSetPreviewDisplay` | `nativeSetOutputMode(DIRECT_WINDOW)` | Direct mapping |
| `nativeSetFrameCallback` | `nativeFrameBufferAcquireBuffer` | Pull vs push |
| `IFrameCallback.onFrame` | Poll loop | Consumer-driven |
| Pointer cast handle | HandleManager handle | Drop-in compatible |

### 3.2 Behavioral Differences

| Aspect | Legacy | Modern |
|--------|--------|--------|
| Frame timing | Push (callback) | Pull (acquire) |
| Memory copy | Yes (ByteBuffer) | No (zero-copy) |
| GPU integration | No | Yes (EGLImage) |
| Fence sync | No | Yes (bidirectional) |

---

## 4. Client Migration Guide

### 4.1 From Legacy to Modern

```kotlin
// LEGACY
class LegacyPreview : IFrameCallback {
    fun start() {
        camera.setFrameCallback(this, PIXEL_FORMAT_RGBX)
        camera.setPreviewDisplay(surface)
        camera.startPreview()
    }

    override fun onFrame(frame: ByteBuffer) {
        // Copy to bitmap, render
    }
}

// MODERN
class ModernPreview {
    fun start() {
        ringHandle = FrameBufferManager.nativeFrameBufferAllocate(
            cameraHandle, width, height, format
        )
        camera.setOutputMode(OutputMode.RING_BUFFER)
        camera.startPreview()

        // Start consumer loop
        frameConsumerJob = scope.launch {
            while (isActive) {
                val buffer = FrameBufferManager.nativeFrameBufferAcquireBuffer(ringHandle)
                if (buffer != null) {
                    renderWithEGL(buffer)
                    FrameBufferManager.nativeFrameBufferReleaseBuffer(ringHandle)
                }
            }
        }
    }
}
```

### 4.2 Incremental Migration

1. **Keep legacy working** - No code changes required
2. **Add modern path** - New clients use AHardwareBuffer
3. **Test in parallel** - Both paths work simultaneously
4. **Measure performance** - Compare frame rates, latency
5. **Switch production** - Move to modern path
6. **Deprecate legacy** - Mark for future removal

---

## 5. Risk Mitigation

### 5.1 Rollback Strategy

```kotlin
// Feature flag for path selection
val useModernPath = BuildConfig.USE_HARDWARE_BUFFER_PREVIEW

fun setupPreview() {
    if (useModernPath) {
        setupModernPreview()
    } else {
        setupLegacyPreview()
    }
}
```

### 5.2 Telemetry

```kotlin
// Track migration success
analytics.track("preview_mode", mapOf(
    "mode" to outputMode.name,
    "fps" to measuredFps,
    "drops" to droppedFrames
))
```

---

## 6. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| JNI-010-001 | Info | Parallel operation works | No breaking changes |
| JNI-010-002 | Info | OutputMode bridges both | Clean abstraction |
| JNI-010-003 | Low | Legacy IFrameCallback retained | Deprecate eventually |
| JNI-010-004 | Info | Feature flags available | Safe rollback |
| JNI-010-005 | Info | Same HandleManager for both | No handle migration |

---

## 7. Cross-Reference

| Document | Relationship |
|----------|--------------|
| **OutputMode.h** | Routing abstraction |
| **JNI-001** | Method inventory |
| **JNI-003** | Frame delivery comparison |

---

*End of JNI-010*
