# ScopeCam-Engine WARM Gate Directive

**Document Type:** Binding Implementation Directive  
**Source Authority:** ARCH-DECISIONS-001-R2 + WARM Gate Analysis (2026-01-14)  
**Applies To:** `scopecam-engine` repository  
**Priority:** P0 - CRITICAL
**Revision:** R2 (2026-01-14) - Added SurfaceLeaseController pattern

---

## Executive Summary

**TWO critical architectural issues** have been identified in ScopeCam:

1. **WARM Gate Issue:** Session eligibility checks use Java-layer FD (always `-1` with `openSimple()`)
2. **Surface Lease Race:** Two competing paths attach/detach surfaces, causing "19ms detach" after attach

**Evidence:** Render loop starts → 19ms later `detachSurface()` on main thread → frozen first frame.

**Root Cause:** Surface is being treated as a "setting" that can be rewritten from multiple places, rather than a leased resource with a **single owner**.

**This is NOT a USB issue. This is a surface lease churn caused by two competing attachment controllers.**

---

## Part I: The Ownership Model

### Architectural Principle

```
┌─────────────────────────────────────────────────────────────────────┐
│                    OWNERSHIP BOUNDARIES                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  NATIVE OWNS:                         KOTLIN OWNS:                   │
│  ├── USB session (FD after dup)       ├── Android lifecycle          │
│  ├── Preview pipeline                 ├── UI surfaces                │
│  ├── Frame processing                 ├── Surface lease decisions    │
│  └── WARM/HOT state machine           └── Single point of control    │
│                                                                      │
│  RULE: Exactly ONE component may call native attach/detach.          │
│  Everything else REQUESTS through that single owner.                 │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Part II: The WARM Gate Problem

### Current (Broken) Pattern

```kotlin
// ❌ BROKEN: This pattern fails with openSimple()
fun canEnterWarmState(): Boolean {
    return sessionHandle != null && usbFd >= 0
}

// ❌ BROKEN: mCtrlBlock is null when using openSimple()
fun checkConnection(): Boolean {
    return currentCtrlBlock?.fileDescriptor?.let { it >= 0 } ?: false
}
```

### Why It Fails

1. `openSimple(fd, path)` does NOT populate `mCtrlBlock`
2. Native duplicates the FD with `dup()` and owns it independently
3. Java-layer `getFileDescriptor()` will ALWAYS return `-1`
4. Preview works because NATIVE owns the session, not Java

---

## Part III: The Surface Lease Race Problem

### Current (Broken) Architecture

You have **two independent attach paths** racing:

```
Path A: attachSurfaceToSession() → attaches via RingBufferController
Path B: handleConnectedState() → safeSetPreviewSurfaceRes() → detach/attach swap

Timeline:
  0ms: Path A attaches → native preview thread starts rendering
 19ms: Path B "applies surface/resolution" → performs detach/attach swap
       → preview thread loses ANativeWindow → frozen first frame
```

**This is the classic smell:** Surface is treated as a "setting" you can rewrite from multiple places, rather than a leased resource with a single owner.

### Why Two Paths Exist (The Bug)

| Path | Trigger | Action | Problem |
|------|---------|--------|---------|
| `attachSurfaceToSession()` | Ring buffer setup | Direct native attach | First attach works |
| `safeSetPreviewSurfaceRes()` | State transition | Detach/attach "swap" | **Kills the lease** |

Both think they're responsible for the surface. Neither checks if the other already did it.

---

## Part IV: The Required Fixes

### Fix 1: Replace ALL FD-Based Checks

Search the ScopeCam codebase for:
- `fileDescriptor`
- `usbFd`
- `ctrlBlock`
- `>= 0` checks related to FD

Replace with native-based state queries:

```kotlin
// ✅ CORRECT: Native-based session truth
fun canEnterWarmState(): Boolean {
    val camera = uvcCamera ?: return false
    val state = camera.getPreviewState()
    val diag = camera.querySessionDiagnostic()
    
    return state != UVCCamera.PREVIEW_STATE_COLD &&
           (diag and UVCCamera.DIAG_RUNNING) != 0
}
```

### State Truth Table

| Check | ✅ Correct Source | ❌ WRONG Source |
|-------|------------------|-----------------|
| Session alive? | `getPreviewState() != COLD` | ~~`usbFd >= 0`~~ |
| Thread running? | `(diag & DIAG_RUNNING) != 0` | ~~`ctrlBlock != null`~~ |
| Can go WARM? | `state != COLD && running` | ~~`fd >= 0 && handle != null`~~ |
| Surface bound? | `(diag & DIAG_SURFACE_BOUND) != 0` | ~~Kotlin boolean~~ |

---

### Fix 2: Introduce SurfaceLeaseController (Single Owner)

**Principle:** Exactly ONE place in the app may call native `attachSurface()` / `detachSurface()`. Everything else submits requests to that one place.

```kotlin
/**
 * SINGLE OWNER of all native surface operations.
 * No other component may call native attach/detach directly.
 */
class SurfaceLeaseController(
    private val camera: UVCCamera,
    private val cameraDispatcher: CoroutineDispatcher  // All ops on this thread
) {
    private val mutex = Mutex()
    private var currentSurfaceGeneration: Int = 0
    private var currentOutputMode: OutputMode = OutputMode.IDLE
    
    /**
     * Idempotent surface lease operation.
     * Safe to call multiple times - no-op if already in desired state.
     */
    suspend fun ensureSurfaceLeased(
        surface: Surface,
        surfaceGeneration: Int,
        desiredMode: OutputMode
    ) = withContext(cameraDispatcher) {
        mutex.withLock {
            if (!surface.isValid) {
                Log.w(TAG, "LEASE: Ignoring invalid surface")
                return@withContext
            }
            
            // Query native truth
            val nativeState = camera.getPreviewState()
            val diag = camera.querySessionDiagnostic()
            val nativeHasSurface = (diag and UVCCamera.DIAG_SURFACE_BOUND) != 0
            
            // Check if already in desired state
            val sameSurface = (surfaceGeneration == currentSurfaceGeneration)
            
            if (nativeHasSurface && sameSurface && nativeState == UVCCamera.PREVIEW_STATE_HOT) {
                // Already leased correctly - only adjust output mode if needed
                if (currentOutputMode != desiredMode) {
                    Log.i(TAG, "LEASE: Adjusting output mode to $desiredMode")
                    camera.setOutputMode(desiredMode.nativeValue)
                    currentOutputMode = desiredMode
                }
                return@withContext
            }
            
            // Perform the lease
            Log.i(TAG, "LEASE: Acquiring surface gen=$surfaceGeneration mode=$desiredMode")
            camera.acquireSurfaceLease(surface)
            camera.setOutputMode(desiredMode.nativeValue)
            currentSurfaceGeneration = surfaceGeneration
            currentOutputMode = desiredMode
            
            // Verify
            val afterDiag = camera.querySessionDiagnostic()
            val success = (afterDiag and UVCCamera.DIAG_STATE_HOT) != 0
            if (!success) {
                Log.e(TAG, "LEASE: Failed to enter HOT state, diag=0x${afterDiag.toString(16)}")
            }
        }
    }
    
    /**
     * Release surface lease (HOT → WARM transition).
     */
    suspend fun releaseSurfaceLease(reason: String) = withContext(cameraDispatcher) {
        mutex.withLock {
            val diag = camera.querySessionDiagnostic()
            val hasSurface = (diag and UVCCamera.DIAG_SURFACE_BOUND) != 0
            
            if (!hasSurface) {
                Log.d(TAG, "LEASE: Already released, skipping")
                return@withContext
            }
            
            Log.i(TAG, "LEASE: Releasing surface, reason=$reason")
            camera.suspendSurfaceLease()
            currentOutputMode = OutputMode.IDLE
            
            // Verify
            val afterDiag = camera.querySessionDiagnostic()
            val success = (afterDiag and UVCCamera.DIAG_STATE_WARM) != 0
            if (!success) {
                Log.e(TAG, "LEASE: Failed to enter WARM state, diag=0x${afterDiag.toString(16)}")
            }
        }
    }
}
```

### Key Properties

| Property | Implementation |
|----------|----------------|
| **Idempotent** | "Ensure" means no-op if already correct |
| **Native Truth** | Surface-bound comes from diagnostic bitmask |
| **Single Thread** | All ops on `cameraDispatcher` |
| **Generation Token** | Prevents stale callbacks from affecting new surfaces |

---

### Fix 3: Remove the Second Attachment Path

**Before (Racing):**
```kotlin
// Path A - RingBufferController
fun attachSurfaceToSession() {
    camera.acquireSurfaceLease(surface)  // ❌ Direct call
}

// Path B - State handler  
fun safeSetPreviewSurfaceRes() {
    camera.suspendSurfaceLease()  // ❌ Detach
    camera.acquireSurfaceLease(surface)  // ❌ Re-attach
}
```

**After (Single Owner):**
```kotlin
// Path A - RingBufferController
fun attachSurfaceToSession() {
    // ✅ Request through controller - idempotent
    surfaceLeaseController.ensureSurfaceLeased(
        surface, surfaceGeneration, OutputMode.RING_BUFFER
    )
}

// Path B - State handler
fun safeSetPreviewSurfaceRes() {
    // ✅ Same controller - will no-op if already attached
    surfaceLeaseController.ensureSurfaceLeased(
        surface, surfaceGeneration, OutputMode.DIRECT_WINDOW
    )
}
```

Both paths now go through the same idempotent controller. No race.

---

### Fix 4: Surface Generation Token

Android `Surface` identity is tricky across recreations. Use a monotonic token:

```kotlin
class SurfaceTracker {
    private var surfaceGeneration = AtomicInteger(0)
    
    fun onSurfaceCreated(holder: SurfaceHolder): Pair<Surface, Int> {
        val gen = surfaceGeneration.incrementAndGet()
        Log.i(TAG, "Surface created, generation=$gen")
        return Pair(holder.surface, gen)
    }
    
    fun onSurfaceDestroyed(): Int {
        val gen = surfaceGeneration.get()
        Log.i(TAG, "Surface destroyed, generation=$gen")
        return gen
    }
}
```

This prevents stale callbacks from detaching a newer surface.

---

### Fix 5: Threading Confinement

**RULE:** All native camera control calls must occur on a **single camera thread**.

```kotlin
// ❌ BROKEN: detach on main thread
override fun surfaceDestroyed(holder: SurfaceHolder) {
    camera.suspendSurfaceLease()  // Main thread - WRONG
}

// ✅ CORRECT: dispatch to camera thread
override fun surfaceDestroyed(holder: SurfaceHolder) {
    val gen = surfaceTracker.onSurfaceDestroyed()
    cameraScope.launch(cameraDispatcher) {
        surfaceLeaseController.releaseSurfaceLease("SurfaceDestroyed gen=$gen")
    }
}
```

UI events **enqueue requests**. They don't execute them.

---

## Part V: Surface Lifecycle (Updated Pattern)

### On Surface Creation

```kotlin
// surfaceCreated callback
override fun surfaceCreated(holder: SurfaceHolder) {
    val (surface, generation) = surfaceTracker.onSurfaceCreated(holder)
    
    cameraScope.launch(cameraDispatcher) {
        val state = camera.getPreviewState()
        
        when (state) {
            PREVIEW_STATE_WARM, PREVIEW_STATE_HOT -> {
                // Fast path: instant preview via idempotent ensure
                surfaceLeaseController.ensureSurfaceLeased(
                    surface, generation, currentOutputMode
                )
            }
            PREVIEW_STATE_COLD -> {
                // Cold start - full initialization
                performColdStart(surface, generation)
            }
        }
    }
}
```

### On Surface Destruction

```kotlin
// surfaceDestroyed callback
override fun surfaceDestroyed(holder: SurfaceHolder) {
    val generation = surfaceTracker.onSurfaceDestroyed()
    
    cameraScope.launch(cameraDispatcher) {
        surfaceLeaseController.releaseSurfaceLease("SurfaceDestroyed gen=$generation")
    }
}
```

### On Gallery Navigation

```kotlin
// Before navigating to Gallery
fun onNavigateToGallery() {
    cameraScope.launch(cameraDispatcher) {
        surfaceLeaseController.releaseSurfaceLease("NavigateToGallery")
        // FGS keeps USB alive - instant return later
    }
}
```

---

## Part VI: Guardrails

### Lease Sequence Logging

Add traceability to prevent regression:

```kotlin
class SurfaceLeaseController(...) {
    private var leaseSeq = AtomicInteger(0)
    
    private fun logLeaseOp(action: String, reason: String) {
        val seq = leaseSeq.incrementAndGet()
        val thread = Thread.currentThread().name
        Log.i(TAG, "LEASE seq=$seq action=$action reason=$reason thread=$thread")
    }
    
    suspend fun ensureSurfaceLeased(...) {
        // ...
        logLeaseOp("ATTACH", "SurfaceCreated gen=$surfaceGeneration")
        camera.acquireSurfaceLease(surface)
    }
    
    suspend fun releaseSurfaceLease(reason: String) {
        // ...
        logLeaseOp("DETACH", reason)
        camera.suspendSurfaceLease()
    }
}
```

### Debug Assertions

```kotlin
// In debug builds, assert invariants
fun assertLeaseInvariants(lastAttachTime: Long, detachReason: String) {
    val elapsed = SystemClock.elapsedRealtime() - lastAttachTime
    
    // No detach within 100ms of attach (unless explicit reason)
    if (elapsed < 100 && detachReason != "SurfaceDestroyed" && detachReason != "StopPreview") {
        Log.e(TAG, "INVARIANT VIOLATION: Detach $elapsed ms after attach, reason=$detachReason")
        if (BuildConfig.DEBUG) {
            throw IllegalStateException("Surface lease race detected")
        }
    }
    
    // No detach from main thread
    if (Looper.myLooper() == Looper.getMainLooper()) {
        Log.e(TAG, "INVARIANT VIOLATION: Detach on main thread")
        if (BuildConfig.DEBUG) {
            throw IllegalStateException("Surface detach on main thread")
        }
    }
}
```

### Expected Log Pattern (Success)

```
LEASE seq=12 action=ATTACH reason=SurfaceCreated gen=5 thread=CameraThread
LEASE seq=13 action=DETACH reason=NavigateToGallery thread=CameraThread
LEASE seq=14 action=ATTACH reason=ReturnFromGallery gen=6 thread=CameraThread
```

### Bug Pattern (What You Had)

```
LEASE seq=12 action=ATTACH reason=SurfaceCreated gen=5 thread=CameraThread
LEASE seq=13 action=DETACH reason=safeSetPreviewSurfaceRes thread=main  ← BUG!
LEASE seq=14 action=ATTACH reason=safeSetPreviewSurfaceRes thread=main  ← BUG!
```

---

## Part VII: Foreground Service Requirement

### Manifest

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>

<service
    android:name=".service.UsbCameraService"
    android:foregroundServiceType="connectedDevice"
    android:exported="false" />
```

### Lifecycle Rules

| Event | FGS Action |
|-------|------------|
| USB attached | `start()` |
| Gallery navigation | **DO NOT STOP** |
| Screen lock | **DO NOT STOP** |
| USB detached | `stop()` |

---

## Part VIII: Implementation Checklist

### Phase 1: Surface Lease Single Owner (P0 - IMMEDIATE)

- [ ] Create `SurfaceLeaseController` class
- [ ] Move ALL `acquireSurfaceLease()` / `suspendSurfaceLease()` calls into controller
- [ ] Add camera-thread confinement (`cameraDispatcher`)
- [ ] Add surface generation tracking
- [ ] Make `ensureSurfaceLeased()` idempotent

### Phase 2: Remove Racing Paths (P0 - IMMEDIATE)

- [ ] Identify all paths that call native surface attach/detach
- [ ] Refactor `attachSurfaceToSession()` to use controller
- [ ] Refactor `safeSetPreviewSurfaceRes()` to use controller
- [ ] Remove direct native calls outside controller
- [ ] Add debug assertions for main-thread violations

### Phase 3: WARM Gate Fix (P0)

- [ ] Search for `fileDescriptor`, `usbFd`, `ctrlBlock` checks
- [ ] Replace ALL with `getPreviewState()` / `querySessionDiagnostic()`
- [ ] Add diagnostic logging at lifecycle edges

### Phase 4: FGS Implementation (P1)

- [ ] Add manifest permissions
- [ ] Implement `UsbCameraService`
- [ ] Wire up lifecycle correctly

### Phase 5: Verification

- [ ] No "19ms detach after attach" in logs
- [ ] 20x Gallery navigation without crash
- [ ] 20x screen rotation without crash
- [ ] All lease operations on camera thread

---

## Part IX: Success Criteria

| Test | Expected Result |
|------|-----------------|
| First frame displays | No frozen frame (attach not followed by immediate detach) |
| Gallery → Back | Instant preview (no "connecting...") |
| `getPreviewState()` in WARM | Returns `1` (not `-1`) |
| Lease operations | All on camera thread, none on main |
| Lease sequence | No DETACH within 100ms of ATTACH (except explicit reasons) |

### Log Patterns to Verify

**Good:**
```
LEASE seq=12 action=ATTACH reason=SurfaceCreated gen=5 thread=CameraThread
(preview starts rendering...)
(user navigates to Gallery)
LEASE seq=13 action=DETACH reason=NavigateToGallery thread=CameraThread
```

**Bad (what you're seeing now):**
```
LEASE seq=12 action=ATTACH reason=SurfaceCreated gen=5 thread=CameraThread
(19ms later)
LEASE seq=13 action=DETACH reason=safeSetPreviewSurfaceRes thread=main
```

---

## Part X: Code Locations to Modify

Based on the trace, these are the likely culprits:

| File/Function | Issue | Fix |
|---------------|-------|-----|
| `attachSurfaceToSession()` | Direct native call | Route through `SurfaceLeaseController` |
| `handleConnectedState()` | Triggers swap | Remove swap, use idempotent ensure |
| `safeSetPreviewSurfaceRes()` | Detach/attach swap | Remove, or make it request-only |
| Surface callbacks | Main thread ops | Dispatch to camera thread |

---

## Reference

- Library API: [api-reference.md](../docs/api-reference.md)
- Integration Guide: [ScopeCam-Integration-Guide.md](../docs/ScopeCam-Integration-Guide.md)
- Architecture: [architecture.md](../docs/architecture.md)

**This directive is BINDING. Non-compliance results in:**
- Frozen first frame (surface lease race)
- Broken Gallery navigation (wrong WARM gate)
- Potential crashes (main-thread violations)
