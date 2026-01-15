---
title: ScopeCam Native Integration Guide
category: integration
component: jni
status: active
version: "2.0"
last_updated: 2026-01-14
tags: [scopecam, kotlin, jni, integration, stability, warm-state]
priority: critical
---

# ScopeCam Native Integration Guide

This document provides integration instructions for the ScopeCam Kotlin agent to wire up the native stability APIs from UVCCamera library.

> **⚠️ CRITICAL UPDATE (2026-01-14):** This guide has been updated with mandatory WARM state gating patterns. Consumer applications MUST use native-based state checks, NOT Java-layer FD checks. See [Section 0: WARM State Architecture](#0-warm-state-architecture-critical).

## Overview

The UVCCamera library (v2.x.x+) now exposes:
- **WARM State Machine**: Native-controlled COLD→WARM→HOT transitions
- **Surface Lease API**: `suspendSurfaceLease()` / `acquireSurfaceLease()`
- **Native Diagnostics**: `getPreviewState()` / `querySessionDiagnostic()`
- **Readiness Callback**: Know when native preview thread is ready
- **Graduated Cleanup**: Cleanup at 4 different levels
- **Hard Reset**: Nuclear option for DeviceBusy recovery

---

## 0. WARM State Architecture (CRITICAL)

### 0.1 The Ownership Model

When using `openSimple(fd, path)`, the native layer owns the USB session:

```
┌────────────────────────────────────────────────────────────────────┐
│                    OWNERSHIP AFTER openSimple()                     │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  NATIVE OWNS:                        KOTLIN OWNS:                   │
│  ├── USB file descriptor (dup'd)     ├── Android lifecycle          │
│  ├── Session state machine           ├── Surface lifecycle          │
│  ├── Preview thread                  ├── USB permission flow        │
│  └── Frame processing                ├── UsbDeviceConnection        │
│                                      └── Foreground Service         │
│                                                                     │
│  CRITICAL: mCtrlBlock is NULL when using openSimple()               │
│  Java-layer FD checks will ALWAYS fail (-1)                         │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

### 0.2 WARM Gate: The Correct Pattern

**❌ PROHIBITED - Java-layer FD checks:**

```kotlin
// BROKEN: This pattern fails with openSimple()
fun canEnterWarmState_WRONG(): Boolean {
    return sessionHandle != null && usbFd >= 0  // ❌ ALWAYS FAILS
}

fun checkConnection_WRONG(): Boolean {
    return currentCtrlBlock?.fileDescriptor?.let { it >= 0 } ?: false  // ❌ ALWAYS FALSE
}
```

**✅ REQUIRED - Native-based state checks:**

```kotlin
// CORRECT: Query native layer for session truth
fun canEnterWarmState(): Boolean {
    val camera = uvcCamera ?: return false
    val state = camera.getPreviewState()
    val diag = camera.querySessionDiagnostic()
    
    // Native session is alive and streaming
    return state != UVCCamera.PREVIEW_STATE_COLD &&
           (diag and UVCCamera.DIAG_RUNNING) != 0
}

fun isSessionHealthy(): Boolean {
    val diag = uvcCamera?.querySessionDiagnostic() ?: return false
    
    val running = (diag and UVCCamera.DIAG_RUNNING) != 0
    val notStagnant = (diag and UVCCamera.DIAG_STAGNATION) == 0
    
    return running && notStagnant
}
```

### 0.3 State Truth Table

| Check | ✅ Correct Source | ❌ WRONG Source |
|-------|------------------|-----------------|
| Session alive? | `getPreviewState() != COLD` | ~~`usbFd >= 0`~~ |
| Thread running? | `(diag & DIAG_RUNNING) != 0` | ~~`ctrlBlock != null`~~ |
| Can go WARM? | `state != COLD && running` | ~~`fd >= 0 && handle != null`~~ |
| Stagnation? | `(diag & DIAG_STAGNATION) != 0` | N/A |

### 0.4 Surface Lifecycle Integration

```kotlin
class CameraLifecycleManager(private val camera: UVCCamera) {
    
    /**
     * Call BEFORE surface destruction (onSurfaceDestroyed, onPause, Gallery nav)
     */
    fun onSurfaceGoingAway() {
        // 1. Transition to WARM (native continues streaming, no render)
        camera.suspendSurfaceLease()
        
        // 2. Verify transition succeeded
        val diag = camera.querySessionDiagnostic()
        val isWarm = (diag and UVCCamera.DIAG_STATE_WARM) != 0
        val stillRunning = (diag and UVCCamera.DIAG_RUNNING) != 0
        
        if (!isWarm || !stillRunning) {
            Log.w(TAG, "WARM transition issue: diag=0x${diag.toString(16)}")
        }
    }
    
    /**
     * Call when surface becomes available (onSurfaceCreated, onResume)
     */
    fun onSurfaceAvailable(surface: Surface) {
        when (camera.getPreviewState()) {
            UVCCamera.PREVIEW_STATE_WARM -> {
                // Fast path: instant preview resume
                camera.acquireSurfaceLease(surface)
                verifyHotState()
            }
            UVCCamera.PREVIEW_STATE_HOT -> {
                // Surface swap scenario
                camera.suspendSurfaceLease()
                camera.acquireSurfaceLease(surface)
                verifyHotState()
            }
            UVCCamera.PREVIEW_STATE_COLD -> {
                // Cold start - full initialization needed
                performColdStart(surface)
            }
        }
    }
    
    private fun verifyHotState() {
        val diag = camera.querySessionDiagnostic()
        if ((diag and UVCCamera.DIAG_STATE_HOT) == 0) {
            Log.e(TAG, "Failed HOT transition: diag=0x${diag.toString(16)}")
            // Trigger recovery
        }
    }
}
```

### 0.5 Single-Owner Surface Lease Pattern

**CRITICAL:** Exactly ONE component may call native `attachSurface()` / `detachSurface()`. All other components must request through that single owner.

This prevents the "attach then detach 19ms later" race condition where two paths compete to control the surface.

See `patches/SCOPECAM_ENGINE_WARM_GATE_DIRECTIVE.md` for the complete `SurfaceLeaseController` implementation.

**Key requirements:**
- All surface operations through `SurfaceLeaseController`
- All operations on a single camera thread (not main thread)
- Operations are idempotent ("ensure" semantics)
- Surface identity tracked via generation token

### 0.6 Required Diagnostic Logging

Add logging at every lifecycle edge:

```kotlin
private fun logCameraState(event: String) {
    val state = camera?.getPreviewState() ?: -1
    val diag = camera?.querySessionDiagnostic() ?: 0
    
    val stateName = when (state) {
        UVCCamera.PREVIEW_STATE_COLD -> "COLD"
        UVCCamera.PREVIEW_STATE_WARM -> "WARM"
        UVCCamera.PREVIEW_STATE_HOT -> "HOT"
        else -> "UNKNOWN($state)"
    }
    
    Log.i(TAG, "CAMERA_STATE [$event]: state=$stateName, diag=0x${diag.toString(16)}")
}

// Call at: onSurfaceCreated, onSurfaceDestroyed, onPause, onResume, Gallery nav
```

---

## 0.7 Foreground Service Requirement (Android 14+)

USB sessions require a Foreground Service with `connectedDevice` type to survive lifecycle transitions.

### Manifest Declaration

```xml
<!-- Base FGS permission (Android 9+) -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>

<!-- USB camera FGS type (Android 14+) -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>

<application>
    <service
        android:name=".service.UsbCameraService"
        android:foregroundServiceType="connectedDevice"
        android:exported="false" />
</application>
```

### Service Implementation

```kotlin
class UsbCameraService : Service() {
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = createNotification()
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        
        return START_NOT_STICKY
    }
    
    companion object {
        fun start(context: Context) {
            val intent = Intent(context, UsbCameraService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
        
        fun stop(context: Context) {
            context.stopService(Intent(context, UsbCameraService::class.java))
        }
    }
}
```

### FGS Lifecycle Rules

| Event | FGS Action |
|-------|------------|
| USB device attached | `UsbCameraService.start()` |
| Gallery navigation | **DO NOT STOP** - WARM state keeps USB alive |
| Screen lock | **DO NOT STOP** - FGS maintains connection |
| USB device detached | `UsbCameraService.stop()` |
| App closed by user | `UsbCameraService.stop()` |

---

## 0.8 Prohibited Patterns

The following patterns are **PROHIBITED** in ScopeCam:

### FD-Based Truth (Wrong Layer)

```kotlin
// ❌ Java-layer FD check (always fails with openSimple)
if (usbDeviceConnection?.fileDescriptor?.let { it >= 0 } == true) { }

// ❌ ctrlBlock null check (ctrlBlock is null with openSimple)
if (currentCtrlBlock != null) { }

// ❌ Caching FD from Java layer
val cachedFd = usbDeviceConnection?.fileDescriptor  // Will be -1
```

### Surface Lease Violations

```kotlin
// ❌ Multiple paths calling native attach/detach
class RingBufferController {
    fun attachSurfaceToSession() {
        camera.acquireSurfaceLease(surface)  // ❌ Direct call
    }
}

class StateHandler {
    fun safeSetPreviewSurfaceRes() {
        camera.suspendSurfaceLease()         // ❌ Competing detach
        camera.acquireSurfaceLease(surface)  // ❌ Competing attach
    }
}

// ❌ Surface operations on main thread
override fun surfaceDestroyed(holder: SurfaceHolder) {
    camera.suspendSurfaceLease()  // ❌ Main thread!
}
```

### Lifecycle Violations

```kotlin
// ❌ Full disconnect on surface destroy
fun onSurfaceDestroyed() {
    camera.close()    // ❌ Kills USB session
    camera.release()  // ❌ Full teardown
}

// ❌ Stopping FGS on Gallery navigation
fun onPause() {
    UsbCameraService.stop(context)  // ❌ USB will drop
}
```

### Video Recording Violations

```kotlin
// ❌ Two competing drain paths (causes MediaCodec crash)
class VideoRecorder {
    fun drainEncoder() {
        encoder.dequeueOutputBuffer(...)  // Path A
    }
    
    fun drainEncoderFinal() {
        encoder.dequeueOutputBuffer(...)  // Path B - RACE!
    }
    
    fun stop() {
        encodingJob?.cancel()
        drainEncoderFinal()  // ❌ Two dequeue paths active
    }
}

// ❌ Cancel + final drain pattern
suspend fun stopRecording() {
    encodingJob?.cancel()      // Cancel drain loop
    drainEncoderFinal()        // Start ANOTHER drain → RACE!
}
```

---

## 0.9 Video Recording Architecture

Video recording follows the **same single-owner pattern** as surface lease.

**See full directive:** `patches/SCOPECAM_ENGINE_VIDEO_RECORDING_DIRECTIVE.md`

### Recording Invariants

| Invariant | Rule |
|-----------|------|
| **Single Encoder Consumer** | ONE loop drains MediaCodec output |
| **Stop is State Transition** | Not cancellation - orderly shutdown |
| **Muxer Finalization Once** | Stop muxer exactly once |
| **Atomic File Publishing** | Valid video OR discarded + error |

### Correct Stop Pattern

```kotlin
// ✅ CORRECT: Single drain path, orderly shutdown
suspend fun stopRecording() {
    // 1. Signal stop (close inputs, signal EOS)
    closeFrameInput()
    signalEncoderEos()
    
    // 2. Wait for THE SAME drain loop to finish
    drainJob?.join()  // Sees EOS and exits naturally
    
    // 3. Then finalize (exactly once)
    muxer.stop()
    encoder.release()
    publishToMediaStore()
}
```

### RecordingPipelineController

Similar to `SurfaceLeaseController`, create a single owner for codec/muxer:

```kotlin
class RecordingPipelineController(
    private val recordingDispatcher: CoroutineDispatcher  // Single-threaded!
) {
    // THE ONLY code that calls dequeueOutputBuffer
    private suspend fun drainLoop(encoder: MediaCodec, muxer: MediaMuxer) {
        // Runtime assertion: prove single-consumer
        check(drainInProgress.compareAndSet(false, true)) {
            "INVARIANT VIOLATION: Concurrent dequeue!"
        }
        // ... single drain loop ...
    }
}
```

---

## 1. Library Update Required

The ScopeCam app must use the updated UVCCamera library. Update the dependency in your app's `build.gradle`:

```kotlin
implementation("org.uvccamera:lib:1.x.x")  // Use version with stability fixes
```

Or for local development:
```bash
cd /path/to/UVCCamera
./gradlew :lib:publishToMavenLocal
```

---

## 2. Readiness Callback Integration

### Java API (UVCCamera.java)

```java
// Set callback before startPreview()
camera.setReadinessCallback(new IReadinessCallback() {
    @Override
    public void onNativeReady() {
        // Native preview thread is now running
        // Safe to call stopPreview() from now on
    }
});

// Query readiness state (polling alternative)
boolean ready = camera.isReady();
```

### Kotlin Integration Pattern

```kotlin
// In your camera manager or wrapper class
class NativeReadinessCallbackImpl(
    private val onReady: () -> Unit
) : IReadinessCallback {
    override fun onNativeReady() {
        onReady()
    }
}

// Usage in CameraConnectionManager or equivalent:
fun startPreviewWithReadiness(camera: UVCCamera) {
    val readyLatch = CountDownLatch(1)

    camera.setReadinessCallback(NativeReadinessCallbackImpl {
        readyLatch.countDown()
        emitTelemetry("native_ready", mapOf("source" to "callback"))
    })

    camera.startPreview()

    // Wait for readiness with timeout
    val receivedCallback = readyLatch.await(500, TimeUnit.MILLISECONDS)
    if (!receivedCallback) {
        // Fallback: poll isReady()
        emitTelemetry("native_ready", mapOf("source" to "timeout_fallback"))
    }
}
```

### Telemetry Events for Readiness

| Event | Properties | Description |
|-------|------------|-------------|
| `native_ready` | `source: "callback"` | Readiness via JNI callback |
| `native_ready` | `source: "timeout_fallback"` | Readiness via polling after timeout |
| `native_ready_timeout` | `timeout_ms: 500` | No readiness within timeout |

---

## 3. Cleanup Levels Integration

### Java API (UVCCamera.java)

```java
// Cleanup level constants
public static final int CLEANUP_PREVIEW_ONLY = 0;  // Stop preview, keep USB
public static final int CLEANUP_CAMERA = 1;        // Close camera handle
public static final int CLEANUP_INTERFACE = 2;     // Release USB interface
public static final int CLEANUP_FULL = 3;          // Release everything

// Usage
int result = camera.cleanup(UVCCamera.CLEANUP_PREVIEW_ONLY);
int result = camera.cleanup(UVCCamera.CLEANUP_INTERFACE);
```

### Cleanup Level Details

| Level | Constant | Actions | Use Case |
|-------|----------|---------|----------|
| 0 | `CLEANUP_PREVIEW_ONLY` | Stop preview thread | Quick pause, resume expected |
| 1 | `CLEANUP_CAMERA` | Close UVC handle, delete helpers | Camera error recovery |
| 2 | `CLEANUP_INTERFACE` | Release USB interfaces (BEFORE camera close) | DeviceBusy recovery |
| 3 | `CLEANUP_FULL` | Release device, close fd | Full disconnect |

**CRITICAL ORDERING**: Level 2 (INTERFACE) is executed BEFORE Level 1 (CAMERA) internally because releasing USB interfaces requires the camera handle to still be valid.

### Kotlin Integration Pattern

```kotlin
enum class CleanupLevel(val value: Int) {
    PREVIEW_ONLY(0),
    CAMERA(1),
    INTERFACE(2),
    FULL(3)
}

fun cleanup(camera: UVCCamera, level: CleanupLevel): Result<Unit> {
    val startTime = System.currentTimeMillis()

    return try {
        val result = camera.cleanup(level.value)
        val duration = System.currentTimeMillis() - startTime

        emitTelemetry("cleanup_complete", mapOf(
            "level" to level.name,
            "result" to result,
            "duration_ms" to duration
        ))

        if (result == 0) Result.success(Unit)
        else Result.failure(CleanupException(result))
    } catch (e: Exception) {
        emitTelemetry("cleanup_error", mapOf(
            "level" to level.name,
            "error" to e.message
        ))
        Result.failure(e)
    }
}
```

### Telemetry Events for Cleanup

| Event | Properties | Description |
|-------|------------|-------------|
| `cleanup_start` | `level: String` | Cleanup initiated |
| `cleanup_complete` | `level: String, result: Int, duration_ms: Long` | Cleanup finished |
| `cleanup_error` | `level: String, error: String` | Cleanup failed |

---

## 4. Hard Reset Integration

### Java API (UVCCamera.java)

```java
// Nuclear option - forces cleanup without thread join
int result = camera.hardReset();
```

### What hardReset() Does

1. Calls `forceStop()` on preview (sets atomic flags, broadcasts condition variables)
2. Waits 50ms for threads to notice
3. Deletes all callback helpers
4. Force closes camera handle
5. Resets USB device via `libusb_reset_device()`
6. Releases device reference
7. Clears all state

### Kotlin Integration Pattern

```kotlin
suspend fun hardReset(camera: UVCCamera): Result<Unit> {
    emitTelemetry("hard_reset_start", emptyMap())
    val startTime = System.currentTimeMillis()

    return withContext(Dispatchers.IO) {
        try {
            val result = camera.hardReset()
            val duration = System.currentTimeMillis() - startTime

            emitTelemetry("hard_reset_complete", mapOf(
                "result" to result,
                "duration_ms" to duration
            ))

            // After hard reset, device needs re-permission and re-connect
            connectionState.value = ConnectionState.DISCONNECTED

            if (result == 0) Result.success(Unit)
            else Result.failure(HardResetException(result))
        } catch (e: Exception) {
            emitTelemetry("hard_reset_error", mapOf("error" to e.message))
            Result.failure(e)
        }
    }
}
```

### Telemetry Events for Hard Reset

| Event | Properties | Description |
|-------|------------|-------------|
| `hard_reset_start` | - | Hard reset initiated |
| `hard_reset_complete` | `result: Int, duration_ms: Long` | Hard reset finished |
| `hard_reset_error` | `error: String` | Hard reset failed |

---

## 5. Recovery Strategy Pattern

Recommended recovery escalation:

```kotlin
suspend fun attemptRecovery(camera: UVCCamera, error: CameraError): RecoveryResult {
    return when (error) {
        is PreviewError -> {
            // Level 0: Just stop preview
            emitTelemetry("recovery_attempt", mapOf("strategy" to "preview_restart"))
            cleanup(camera, CleanupLevel.PREVIEW_ONLY)
            delay(100)
            camera.startPreview()
            RecoveryResult.Success
        }

        is CameraHandleError -> {
            // Level 1: Close camera, reconnect
            emitTelemetry("recovery_attempt", mapOf("strategy" to "camera_reconnect"))
            cleanup(camera, CleanupLevel.CAMERA)
            delay(200)
            reconnectCamera()
        }

        is DeviceBusyError -> {
            // Level 2: Release interfaces
            emitTelemetry("recovery_attempt", mapOf("strategy" to "interface_release"))
            cleanup(camera, CleanupLevel.INTERFACE)
            delay(300)
            reconnectCamera()
        }

        is UnrecoverableError -> {
            // Level 3+: Hard reset
            emitTelemetry("recovery_attempt", mapOf("strategy" to "hard_reset"))
            hardReset(camera)
            delay(500)
            // User must re-grant permission
            RecoveryResult.RequiresPermission
        }
    }
}
```

---

## 6. Native Logging

The native layer logs to Android logcat with tag `UVCCamera`:

| Level | Message | Meaning |
|-------|---------|---------|
| D | `cleanup called with level N` | Cleanup initiated |
| D | `Releasing USB interfaces` | Interface release in progress |
| D | `Cleaning up camera resources` | Camera handles being closed |
| D | `Full cleanup - releasing device` | Complete teardown |
| W | `stopPreview returned N` | Non-zero return from stopPreview |
| W | `Hard reset initiated` | Hard reset started |
| W | `libusb_release_interface returned X, Y` | Interface release failed |
| D | `Native readiness signaled to Kotlin` | Callback fired |

Filter logcat:
```bash
adb logcat -s UVCCamera:D
```

---

## 7. Complete Telemetry Event Catalog

### Connection Lifecycle
- `native_ready` - Native layer ready for commands
- `native_ready_timeout` - Readiness timeout occurred

### Cleanup Operations
- `cleanup_start` - Cleanup initiated
- `cleanup_complete` - Cleanup successful
- `cleanup_error` - Cleanup failed

### Hard Reset
- `hard_reset_start` - Hard reset initiated
- `hard_reset_complete` - Hard reset successful
- `hard_reset_error` - Hard reset failed

### Recovery
- `recovery_attempt` - Recovery strategy initiated
- `recovery_success` - Recovery successful
- `recovery_failed` - Recovery failed, escalating

### Recommended Telemetry Properties

All events should include:
- `timestamp_ms: Long` - Event timestamp
- `session_id: String` - Camera session identifier
- `device_id: String` - USB device identifier (if available)

---

## 8. Migration Checklist

- [ ] Update UVCCamera library dependency to version with stability fixes
- [ ] Wire up `IReadinessCallback` in camera connection flow
- [ ] Implement `awaitNativeReady()` with timeout fallback
- [ ] Map `CleanupLevel` enum to native constants
- [ ] Wire up `cleanup(level)` calls to native
- [ ] Wire up `hardReset()` call to native
- [ ] Add telemetry events for all operations
- [ ] Implement recovery escalation strategy
- [ ] Test rapid connect/disconnect cycles
- [ ] Test DeviceBusy recovery scenarios

---

## Version History

| Version | Changes |
|---------|---------|
| N1 | Thread safety - atomic flags, guarded joins |
| N2 | Readiness callback - IReadinessCallback, isReady() |
| N3 | Cleanup levels - cleanup(level), releaseInterface() |
| N4 | Hard reset - hardReset(), USB device reset |
