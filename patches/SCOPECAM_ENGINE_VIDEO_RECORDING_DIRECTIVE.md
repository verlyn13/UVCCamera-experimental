# ScopeCam-Engine Video Recording Directive

**Document Type:** Binding Implementation Directive  
**Source Authority:** ARCH-DECISIONS-001-R2 + Video Recording Analysis (2026-01-14)  
**Applies To:** `scopecam-engine` repository  
**Priority:** P0 - CRITICAL  
**Revision:** R2 (2026-01-14) - Added critical bug fixes from expert consultation

---

## Executive Summary

Multiple critical architectural issues have been identified in video recording:

| Bug | Symptom | Root Cause |
|-----|---------|------------|
| **A. Concurrent Dequeue** | `IllegalStateException` crash | Two drain paths racing |
| **B. Channel Reuse** | `frames=0` after first recording | Closed channel not recreated |
| **C. Wrong Exit Condition** | Drain loop exits early | Using scope state vs EOS observation |
| **D. Deadlock Risk** | Stop hangs | Joining frame job before EOS signal |
| **E. No Thread Serialization** | Intermittent codec errors | Multiple threads touching codec |
| **F. No MediaStore Publish** | Video not visible in gallery | Missing publish step |

**This follows the same pattern as the Surface Lease Race:** Multiple paths competing for control of a single-owner resource.

---

## CRITICAL BUG: Channel Lifecycle (The "frames=0" Bug)

**This is likely the #1 cause of "no frames recorded":**

```kotlin
// ❌ BROKEN: Channel created once, closed on stop, never recreated
class VideoRecordingManager {
    private val frameChannel = Channel<VideoFrameData>(CAPACITY)  // Created ONCE
    
    fun stop() {
        frameChannel.close()  // Closed here
    }
    
    fun start() {
        // Channel is STILL CLOSED from previous recording!
        // processFrames() immediately terminates → frames=0
    }
}
```

**Fix: Channel must be PER-SESSION:**

```kotlin
// ✅ CORRECT: Channel created per recording session
class VideoRecordingManager {
    private var frameChannel: Channel<VideoFrameData>? = null
    
    fun start() {
        frameChannel = Channel(CAPACITY)  // Fresh channel per session
        // ... start processing
    }
    
    fun stop() {
        frameChannel?.close()
        frameChannel = null  // Clear for next session
    }
}
```

---

## Part I: Ownership Model (Extended for Recording)

### Architectural Principle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         OWNERSHIP BOUNDARIES                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  NATIVE OWNS:                         KOTLIN OWNS:                           │
│  ├── USB session (FD after dup)       ├── Android lifecycle                  │
│  ├── Preview pipeline                 ├── UI surfaces (SurfaceLeaseController)│
│  ├── Frame production                 ├── Recording lifecycle                │
│  ├── Ring buffer                      ├── MediaCodec/Muxer (single owner)    │
│  ├── PTS/SCR timestamps               ├── MediaStore publishing              │
│  └── WARM/HOT state machine           └── Error handling / user feedback     │
│                                                                              │
│  INVARIANT: ONE component controls each resource. Others REQUEST.            │
│                                                                              │
│  NEW: RecordingPipelineController - single owner of codec/muxer operations   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Recording Invariants

| Invariant | Rule |
|-----------|------|
| **Single Encoder Consumer** | Exactly ONE loop drains MediaCodec output |
| **Stop is State Transition** | Not cancellation chaos - orderly shutdown |
| **Muxer Finalization Once** | Stop muxer exactly once, or fail hard |
| **Atomic File Publishing** | Valid video OR discarded + error surfaced |

---

## Part II: The Recording Bug (Same Pattern as Surface Race)

### Current (Broken) Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  CURRENT: Two competing dequeue paths                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Path A: drainEncoder() ──────────────┐                                      │
│                                       ├──► dequeueOutputBuffer() ─► CRASH   │
│  Path B: drainEncoderFinal() ─────────┘                                      │
│                                                                              │
│  Timeline:                                                                   │
│    0ms: drainEncoder() running in encoding coroutine                         │
│   50ms: stop() called → launches drainEncoderFinal()                         │
│   51ms: BOTH coroutines call dequeueOutputBuffer() → IllegalStateException   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why This Crashes

MediaCodec has a strict rule: **do not call `dequeueOutputBuffer()` concurrently**.

Your design violates this by having:
1. `drainEncoder()` - ongoing drain loop
2. `drainEncoderFinal()` - "final" drain on stop

Both can be active during stop/cancel → race → crash.

**This is identical to the surface lease race**: two paths thinking they control the resource.

---

## Part III: The Correct Pattern (2026-Grade)

### Threading Requirement: Single Codec Dispatcher

**MANDATORY:** All MediaCodec and MediaMuxer calls MUST be on a single-threaded dispatcher:

```kotlin
// ✅ CORRECT: Create a dedicated single-thread dispatcher for all codec ops
private val codecDispatcher = Dispatchers.Default.limitedParallelism(1)
// OR: Executors.newSingleThreadExecutor().asCoroutineDispatcher()

// ❌ BROKEN: Using Dispatchers.Default allows concurrent access
private val scope = CoroutineScope(Dispatchers.Default)  // WRONG!
```

**Why?** Even with the `drainInProgress` assertion, you still have:
- `signalEndOfInputStream()` called from stop thread
- Drain loop calling dequeue
- Potential surface rendering calls

All must be serialized.

---

### Single-Owner Recording Pipeline

```kotlin
/**
 * SINGLE OWNER of all MediaCodec/Muxer operations.
 * 
 * CRITICAL REQUIREMENTS:
 * 1. All codec/muxer calls on codecDispatcher (single-threaded)
 * 2. Channel is PER-SESSION (created in start, closed in stop)
 * 3. Drain loop exits on EOS observation, not scope state
 * 4. Stop signals EOS BEFORE joining frame processing
 */
class RecordingPipelineController {
    // MANDATORY: Single-threaded dispatcher for ALL codec/muxer operations
    private val codecDispatcher = Dispatchers.Default.limitedParallelism(1)
    private val scope = CoroutineScope(codecDispatcher + SupervisorJob())
    
    // State machine
    private sealed class State {
        object Idle : State()
        data class Recording(val sessionId: String) : State()
        data class Stopping(val sessionId: String) : State()
    }
    
    private val state = AtomicReference<State>(State.Idle)
    
    // PER-SESSION resources (created in start, cleared in stop)
    private var frameChannel: Channel<VideoFrameData>? = null
    private var encoder: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var drainJob: Job? = null
    private var frameJob: Job? = null
    
    // Runtime assertion - makes concurrent access impossible
    private val drainInProgress = AtomicBoolean(false)
    
    /**
     * Start recording. Creates FRESH channel, encoder, muxer, starts single drain loop.
     */
    suspend fun startRecording(
        config: RecordingConfig
    ): Result<RecordingSession> = withContext(codecDispatcher) {
        // State transition: Idle → Recording
        check(state.compareAndSet(State.Idle, State.Recording(config.sessionId))) {
            "Cannot start: not idle"
        }
        
        try {
            // CRITICAL: Create FRESH channel per session
            frameChannel = Channel(FRAME_QUEUE_CAPACITY)
            
            encoder = createEncoder(config)
            muxer = createMuxer(config.tempFile)
            
            // Start THE ONLY drain loop
            drainJob = scope.launch {
                drainLoop(config.sessionId)
            }
            
            // Start frame ingestion (feeds encoder input)
            frameJob = scope.launch {
                ingestFrames(config.sessionId)
            }
            
            log("STARTED sessionId=${config.sessionId}")
            Result.success(RecordingSession(config.sessionId, frameChannel!!))
            
        } catch (e: Exception) {
            cleanup()
            state.set(State.Idle)
            Result.failure(e)
        }
    }
    
    /**
     * Stop recording. 
     * 
     * CRITICAL STOP ORDER (prevents deadlock):
     * 1. Transition state → STOPPING
     * 2. Close frame channel (stops intake)
     * 3. Signal EOS to encoder (BEFORE joining frame job!)
     * 4. Await drain completion (with timeout)
     * 5. Stop muxer exactly once
     * 6. Release resources
     * 7. Publish to MediaStore
     */
    suspend fun stopRecording(): Result<Uri> = withContext(codecDispatcher) {
        val currentState = state.get()
        check(currentState is State.Recording) { "Not recording" }
        
        val sessionId = currentState.sessionId
        state.set(State.Stopping(sessionId))
        log("STOP_REQUESTED sessionId=$sessionId")
        
        try {
            // 1. Close frame channel (stops intake)
            frameChannel?.close()
            log("FRAME_CHANNEL_CLOSED")
            
            // 2. Signal EOS IMMEDIATELY (don't wait for frame job!)
            //    This prevents deadlock if frame processing is wedged
            encoder?.signalEndOfInputStream()
            log("EOS_SIGNALED")
            
            // 3. Now join frame job (with timeout - don't block forever)
            withTimeoutOrNull(FRAME_JOB_TIMEOUT_MS) {
                frameJob?.join()
            } ?: log("FRAME_JOB_TIMEOUT (continuing anyway)")
            
            // 4. Wait for drain loop to complete (it will see EOS and exit)
            //    Bounded wait - fail cleanly if exceeded
            val drainCompleted = withTimeoutOrNull(DRAIN_TIMEOUT_MS) {
                drainJob?.join()
                true
            } ?: false
            
            if (!drainCompleted) {
                log("DRAIN_TIMEOUT - forcing cleanup")
                drainJob?.cancel()
            }
            log("DRAIN_COMPLETED")
            
            // 5. Stop muxer (exactly once, here)
            muxer?.stop()
            log("MUXER_STOPPED")
            
            // 6. Release codec
            encoder?.release()
            encoder = null
            log("CODEC_RELEASED")
            
            // 7. Clear per-session resources
            frameChannel = null
            muxer = null
            drainJob = null
            frameJob = null
            
            // 8. Publish to MediaStore
            val uri = publishToMediaStore(sessionId)
            log("MEDIASTORE_PUBLISHED uri=$uri")
            
            state.set(State.Idle)
            Result.success(uri)
            
        } catch (e: Exception) {
            log("STOP_ERROR: ${e.message}")
            cleanup()
            state.set(State.Idle)
            Result.failure(e)
        }
    }
    
    private fun cleanup() {
        frameChannel?.close()
        frameChannel = null
        drainJob?.cancel()
        drainJob = null
        frameJob?.cancel()
        frameJob = null
        try { muxer?.stop() } catch (_: Exception) {}
        muxer = null
        try { encoder?.release() } catch (_: Exception) {}
        encoder = null
    }
    
    companion object {
        private const val FRAME_QUEUE_CAPACITY = 5
        private const val FRAME_JOB_TIMEOUT_MS = 1000L
        private const val DRAIN_TIMEOUT_MS = 3000L
    }
    
    /**
     * THE ONLY drain loop. Single consumer of encoder output.
     * 
     * CRITICAL: Exit condition is EOS observation, NOT scope active state.
     * The loop must drain until it sees BUFFER_FLAG_END_OF_STREAM.
     */
    private suspend fun drainLoop(sessionId: String) {
        log("DRAIN_LOOP_STARTED sessionId=$sessionId drainLoopId=1")
        
        val encoder = this.encoder ?: return
        val muxer = this.muxer ?: return
        
        val bufferInfo = MediaCodec.BufferInfo()
        var trackIndex = -1
        var sawEos = false
        var consecutiveTimeouts = 0
        
        // Exit ONLY on EOS observation (or fatal error / excessive timeouts)
        while (!sawEos) {
            // Runtime assertion: prove single-consumer
            check(drainInProgress.compareAndSet(false, true)) {
                "INVARIANT VIOLATION: Concurrent dequeue detected!"
            }
            
            try {
                val outputIndex = encoder.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)
                
                when {
                    outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        consecutiveTimeouts++
                        // Safety valve: if EOS signaled but we've timed out many times, fail cleanly
                        if (consecutiveTimeouts > MAX_CONSECUTIVE_TIMEOUTS && 
                            state.get() is State.Stopping) {
                            log("DRAIN_TIMEOUT_EXCEEDED - exiting")
                            break
                        }
                        continue
                    }
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        trackIndex = muxer.addTrack(encoder.outputFormat)
                        muxer.start()
                        log("MUXER_STARTED track=$trackIndex")
                        consecutiveTimeouts = 0
                    }
                    outputIndex >= 0 -> {
                        consecutiveTimeouts = 0
                        
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            encoder.releaseOutputBuffer(outputIndex, false)
                            continue
                        }
                        
                        val buffer = encoder.getOutputBuffer(outputIndex)
                        if (buffer != null && trackIndex >= 0) {
                            muxer.writeSampleData(trackIndex, buffer, bufferInfo)
                        }
                        encoder.releaseOutputBuffer(outputIndex, false)
                        
                        // THIS is the correct exit condition: observe EOS on OUTPUT
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            sawEos = true
                            log("DRAIN_EOS_OBSERVED")
                        }
                    }
                }
            } finally {
                drainInProgress.set(false)
            }
        }
        
        log("DRAIN_LOOP_EXITED sessionId=$sessionId sawEos=$sawEos")
    }
    
    companion object {
        private const val FRAME_QUEUE_CAPACITY = 5
        private const val FRAME_JOB_TIMEOUT_MS = 1000L
        private const val DRAIN_TIMEOUT_MS = 3000L
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val MAX_CONSECUTIVE_TIMEOUTS = 100  // ~1 second of timeouts
    }
}
```

### Key Differences from Broken Pattern

| Aspect | ❌ Broken | ✅ Correct |
|--------|----------|-----------|
| Drain paths | Two (`drainEncoder` + `drainEncoderFinal`) | ONE (`drainLoop`) |
| Stop behavior | Cancel + launch final drain | Set state + await existing drain |
| Dequeue calls | Concurrent possible | Single-threaded, guarded |
| Muxer stop | Maybe, maybe not | Exactly once on success path |
| Error handling | Swallow and continue | Fail hard, cleanup, surface |

---

## Part IV: Stop Semantics (Critical)

### Wrong: Cancel and Final Drain

```kotlin
// ❌ BROKEN: Creates two dequeue paths
suspend fun stopRecording() {
    encodingJob?.cancel()  // Cancel drain loop
    drainEncoderFinal()    // Start ANOTHER drain loop → RACE!
    muxer.stop()
}
```

### Correct: State Transition and Join

```kotlin
// ✅ CORRECT: Single drain path, orderly shutdown
suspend fun stopRecording() {
    // 1. Signal stop (close inputs, signal EOS)
    closeFrameInput()
    signalEncoderEos()
    
    // 2. Wait for THE SAME drain loop to finish
    drainJob?.join()  // It will see EOS and exit
    
    // 3. Then finalize
    muxer.stop()
    encoder.release()
    publishToMediaStore()
}
```

The drain loop exits naturally when it sees EOS. No second drain needed.

---

## Part V: File Publishing (Atomic from User's Perspective)

### 2026-Grade MediaStore Pattern

```kotlin
class MediaStorePublisher(private val context: Context) {
    
    /**
     * Publish video atomically using IS_PENDING pattern.
     * User sees either: valid playable video, or nothing (with error).
     */
    suspend fun publishVideo(tempFile: File, metadata: VideoMetadata): Uri {
        val resolver = context.contentResolver
        
        // 1. Create pending entry
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, metadata.fileName)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "DCIM/ScopeCam")
            put(MediaStore.Video.Media.IS_PENDING, 1)  // Not visible yet
        }
        
        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("Failed to create MediaStore entry")
        
        try {
            // 2. Copy temp file to MediaStore
            resolver.openOutputStream(uri)?.use { output ->
                tempFile.inputStream().use { input ->
                    input.copyTo(output)
                }
            }
            
            // 3. Make visible (atomic from user's perspective)
            val updateValues = ContentValues().apply {
                put(MediaStore.Video.Media.IS_PENDING, 0)
            }
            resolver.update(uri, updateValues, null, null)
            
            // 4. Delete temp file
            tempFile.delete()
            
            return uri
            
        } catch (e: Exception) {
            // Cleanup: delete the pending entry
            resolver.delete(uri, null, null)
            tempFile.delete()
            throw e
        }
    }
}
```

### Alternative: Temp File + Rename

```kotlin
// Write to: /data/data/com.app/cache/recording_123.mp4.tmp
// On success: rename to recording_123.mp4, then publish
// On failure: delete .tmp file
```

---

## Part VI: Timestamp Discipline

### Native → Kotlin Frame Data

The native library provides PTS timestamps. Your recording pipeline must:

```kotlin
data class FrameData(
    val buffer: ByteBuffer,
    val timestampNs: Long,     // From native (UVC PTS or system time)
    val frameNumber: Long
)

class TimestampEnforcer {
    private var lastPtsUs = 0L
    private val frameDurationUs = 33_333L  // ~30fps fallback
    
    /**
     * Ensure monotonic PTS for MediaCodec.
     * MediaCodec/muxer do not tolerate regressions.
     */
    fun enforcePts(inputNs: Long): Long {
        val inputUs = inputNs / 1000
        
        val outputUs = if (inputUs <= lastPtsUs) {
            // Regression detected - use fallback
            val corrected = lastPtsUs + frameDurationUs
            log("PTS_CORRECTED input=$inputUs output=$corrected")
            corrected
        } else {
            inputUs
        }
        
        lastPtsUs = outputUs
        return outputUs
    }
}
```

---

## Part VII: Performance (Critical for Real-Time)

### 🚨 WRONG: Bitmap Decode Pipeline

The current pattern is **not viable for production**:

```kotlin
// ❌ BROKEN: CPU bitmap decode kills real-time performance
fun processFrame(frameData: ByteArray) {
    val bitmap = BitmapFactory.decodeByteArray(frameData, 0, frameData.size)  // GC churn!
    surfaceRenderer?.renderFrame(bitmap, ...)  // CPU copy!
}
```

**Problems:**
- Crushes CPU and GC
- Breaks real-time at 30fps
- Introduces latency and frame drops
- OOM on high-res streams

### ✅ CORRECT: Surface Input Encoding (2026-Grade)

```kotlin
// Recording should tap into native ring buffer / GL texture path
// NOT decode every frame to Bitmap

// Option 1: Surface input encoder (best)
val inputSurface = encoder.createInputSurface()
// Native or GL renders directly to this surface

// Option 2: If MJPEG, use native decode (libjpeg-turbo)
// Upload to GL texture, render to encoder surface - no Bitmap
```

**Architecture alignment:** Native owns capture pipeline. Recording should consume from native ring buffer with stable memory strategy (already exists).

### 🚨 WRONG: Frame Copy on Every onFrame()

```kotlin
// ❌ BROKEN: Enormous memory churn at 720p/1080p
fun onFrame(frameData: ByteArray) {
    val data = frameData.copyOf()  // Full copy every frame!
    channel.send(VideoFrameData(data, ...))
}
```

**Fix:** Use ring buffer reference, pooled buffers, or native handles.

---

## Part VIII: Frame Routing (The "frames=0" Diagnosis)

### Root Causes (Check in Order)

1. **Closed channel bug** (most likely)
   - Channel created once, closed on first stop, never recreated
   - Fix: per-session channel

2. **Frame routing not enabled**
   - Preview consumes from RingBufferController
   - Recording listens to different flow that isn't wired
   - Fix: Recording must explicitly subscribe to native callback path

3. **Service boundary not wired**
   - `VideoRecordingManager.onFrame()` never called
   - Add intake log at boundary: `RECORDING [FRAME_INTAKE] count=... bytes=...`

### Service-Owned Recording Start Procedure

```kotlin
// In CameraService (not UI!)
suspend fun startRecording(config: RecordingConfig): Result<RecordingSession> {
    // 1. Enable frame emission from native (if gated)
    cameraManager.safeEnableCaptureFrames()
    log("FRAMES_ENABLED")
    
    // 2. Start recording pipeline
    val session = recordingController.startRecording(config)
    
    // 3. Attach recording consumer to stream
    cameraManager.frames()
        .onEach { frame -> recordingController.onFrame(frame) }
        .launchIn(recordingScope)
    log("RECORDING_CONSUMER_ATTACHED")
    
    // 4. Verify first frame arrives (with timeout)
    val firstFrame = withTimeoutOrNull(2000) {
        recordingController.awaitFirstFrame()
    }
    if (firstFrame == null) {
        log("ERROR: No frames received - aborting")
        recordingController.stopRecording()
        return Result.failure(NoFramesException())
    }
    
    return Result.success(session)
}
```

### Pro Expectation

Recording should consume from the **same native pipeline as preview**, ideally from the ring buffer:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Native Ring Buffer                                                  │
│       │                                                              │
│       ├──► Preview (SurfaceView)                                     │
│       │                                                              │
│       └──► Recording (MediaCodec input surface)                      │
│            Same source, single native pipeline                       │
└─────────────────────────────────────────────────────────────────────┘
```

NOT two parallel flows where one can be off.

---

## Part IX: Runtime Assertions (Seatbelt)

Add these to catch violations immediately:

```kotlin
class RecordingInvariants {
    private val drainInProgress = AtomicBoolean(false)
    private val muxerStopped = AtomicBoolean(false)
    
    fun enterDrain() {
        check(drainInProgress.compareAndSet(false, true)) {
            "INVARIANT VIOLATION: Concurrent dequeue detected!"
        }
    }
    
    fun exitDrain() {
        drainInProgress.set(false)
    }
    
    fun stopMuxer() {
        check(muxerStopped.compareAndSet(false, true)) {
            "INVARIANT VIOLATION: Muxer stop called twice!"
        }
    }
}
```

In debug builds, these throw immediately on violation. In release, they can log and report.

---

## Part X: Logging (Golden Trace)

### Required Log Events

```kotlin
enum class RecordingEvent {
    START_REQUESTED,
    ENCODER_CONFIGURED,
    DRAIN_LOOP_STARTED,
    MUXER_STARTED,
    FIRST_FRAME_ENCODED,
    STOP_REQUESTED,
    EOS_SIGNALED,
    DRAIN_EOS_OBSERVED,
    DRAIN_LOOP_EXITED,
    MUXER_STOPPED,
    CODEC_RELEASED,
    MEDIASTORE_PUBLISHED,
    DONE,
    ERROR
}

fun logRecording(event: RecordingEvent, sessionId: String, extra: String = "") {
    Log.i(TAG, "RECORDING [$event] sessionId=$sessionId $extra")
}
```

### Golden Trace (What Success Looks Like)

```
RECORDING [START_REQUESTED] sessionId=rec_001
RECORDING [ENCODER_CONFIGURED] sessionId=rec_001 codec=video/avc 1920x1080
RECORDING [DRAIN_LOOP_STARTED] sessionId=rec_001 drainLoopId=1
RECORDING [MUXER_STARTED] sessionId=rec_001 track=0
RECORDING [FIRST_FRAME_ENCODED] sessionId=rec_001 pts=0
... (frames encoding) ...
RECORDING [STOP_REQUESTED] sessionId=rec_001
RECORDING [EOS_SIGNALED] sessionId=rec_001
RECORDING [DRAIN_EOS_OBSERVED] sessionId=rec_001
RECORDING [DRAIN_LOOP_EXITED] sessionId=rec_001
RECORDING [MUXER_STOPPED] sessionId=rec_001
RECORDING [CODEC_RELEASED] sessionId=rec_001
RECORDING [MEDIASTORE_PUBLISHED] sessionId=rec_001 uri=content://media/external/video/media/12345
RECORDING [DONE] sessionId=rec_001 duration=3.2s
```

### Bug Pattern (What You're Seeing Now)

```
RECORDING [START_REQUESTED] sessionId=rec_001
RECORDING [DRAIN_LOOP_STARTED] sessionId=rec_001 drainLoopId=1
RECORDING [STOP_REQUESTED] sessionId=rec_001
RECORDING [DRAIN_LOOP_STARTED] sessionId=rec_001 drainLoopId=2  ← BUG: Second drain!
<crash: IllegalStateException in dequeueOutputBuffer>
```

---

## Part XI: Implementation Checklist

### Phase 1: Fix Critical Bugs (P0 - IMMEDIATE)

**Bug A: Channel Reuse (frames=0)**
- [ ] Make `frameChannel` per-session (created in start, null'd in stop)
- [ ] Verify: second recording receives frames

**Bug B: Codec Thread Serialization**
- [ ] Create `codecDispatcher = Dispatchers.Default.limitedParallelism(1)`
- [ ] Ensure ALL MediaCodec/MediaMuxer calls happen on this dispatcher
- [ ] Verify: `signalEndOfInputStream()` also on codec dispatcher

**Bug C: Drain Loop Exit Condition**
- [ ] Remove `isActive()` check from drain loop
- [ ] Exit ONLY on `BUFFER_FLAG_END_OF_STREAM` observation
- [ ] Add timeout safety valve for excessive TRY_AGAIN_LATER

**Bug D: Stop Sequencing (Deadlock Prevention)**
- [ ] Signal EOS BEFORE joining frame processing job
- [ ] Add bounded timeouts on all joins
- [ ] Ensure stop completes even if frame processing is wedged

### Phase 2: Single Drain Loop (P0)

- [ ] Create `RecordingPipelineController` class
- [ ] Implement single `drainLoop()` as THE ONLY dequeue path
- [ ] Remove `drainEncoderFinal()` entirely
- [ ] Add `drainInProgress` runtime assertion

### Phase 3: MediaStore Publishing (P0)

- [ ] Implement `IS_PENDING` MediaStore pattern
- [ ] Handle failure: delete pending entry, surface error
- [ ] Log `MEDIASTORE_PUBLISHED uri=... size=... duration=...`
- [ ] Verify: valid video visible in gallery, or nothing

### Phase 4: Frame Routing Verification (P0)

- [ ] Add intake log at service boundary: `FRAME_INTAKE count=... bytes=...`
- [ ] Verify frames flow: native → channel → encoder
- [ ] Ensure recording uses same source as preview (ring buffer)
- [ ] Add "first frame received" verification in start procedure

### Phase 5: Performance (P1 - Plan Now, Execute Later)

- [ ] Identify Bitmap decode usage (mark as dev-only if keeping)
- [ ] Plan Surface input encoding path from native ring buffer
- [ ] Remove per-frame `copyOf()` - use pooled buffers or native handles

### Phase 6: Verification

- [ ] Test 1: Record 2-3s → stop → save (expect: visible, playable)
- [ ] Test 2: Record 2-3s → stop quickly (<300ms) (expect: no crash)
- [ ] Test 3: Record → stop → record again (expect: frames in second recording)
- [ ] Verify: `drainLoopId` never duplicated
- [ ] Verify: All codec calls on single thread
- [ ] Verify: Golden trace in logs

---

## Part XII: Success Criteria

| Test | Expected Result |
|------|-----------------|
| Normal recording | Valid MP4, visible in gallery, correct duration |
| Quick stop (<300ms) | Either valid short video, or clean failure + user feedback |
| **Second recording** | Frames received (channel recreated) |
| `drainLoopId` | Never more than 1 per recording |
| Dequeue calls | Always single-threaded (assertion never trips) |
| Muxer stop | Exactly once per recording |
| EOS drain | Loop exits on EOS observation, not scope state |
| Stop timeout | Completes within 5s even if frame processing wedged |
| Crash recovery | Temp files cleaned up, no corrupt videos visible |

### Critical Bug Verification

| Bug | How to Verify |
|-----|---------------|
| **A. Channel Reuse** | Record → stop → record again → frames > 0 |
| **B. Thread Serialization** | Add thread name logging to all codec calls |
| **C. Drain Exit** | Log shows `DRAIN_EOS_OBSERVED` before `DRAIN_LOOP_EXITED` |
| **D. Stop Deadlock** | Stop completes with wedged frame processing |
| **E. MediaStore** | Video appears in gallery after stop |

---

## Reference

- Surface Lease Pattern: `patches/SCOPECAM_ENGINE_WARM_GATE_DIRECTIVE.md`
- Native Frame Timestamps: `docs/PTS_SCR_PLUMBING.md`
- Architecture: `docs/architecture.md`

**This directive is BINDING. Non-compliance results in:**
- MediaCodec crashes (concurrent dequeue)
- `frames=0` on second recording (channel reuse bug)
- Stop hangs (deadlock)
- Corrupt/invisible recordings
- User data loss
