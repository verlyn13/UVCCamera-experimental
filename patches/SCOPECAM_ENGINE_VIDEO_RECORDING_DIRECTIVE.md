# ScopeCam-Engine Video Recording Directive

**Document Type:** Binding Implementation Directive  
**Source Authority:** ARCH-DECISIONS-001-R2 + Video Recording Analysis (2026-01-14)  
**Applies To:** `scopecam-engine` repository  
**Priority:** P0 - CRITICAL  
**Revision:** R1 (2026-01-14)

---

## Executive Summary

A critical architectural issue has been identified in video recording: **concurrent access to MediaCodec's `dequeueOutputBuffer()`** from multiple coroutines (`drainEncoder()` and `drainEncoderFinal()`).

**Root Cause:** Violation of MediaCodec's single-consumer rule. Two coroutines racing to dequeue during stop/cancel.

**This follows the same pattern as the Surface Lease Race:** Multiple paths competing for control of a single-owner resource.

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

### Single-Owner Recording Pipeline

```kotlin
/**
 * SINGLE OWNER of all MediaCodec/Muxer operations.
 * Mirrors SurfaceLeaseController pattern for recording.
 */
class RecordingPipelineController(
    private val recordingDispatcher: CoroutineDispatcher  // Single-threaded!
) {
    private val scope = CoroutineScope(recordingDispatcher + SupervisorJob())
    
    // State machine
    private sealed class State {
        object Idle : State()
        data class Recording(val sessionId: String) : State()
        data class Stopping(val sessionId: String) : State()
    }
    
    private val state = AtomicReference<State>(State.Idle)
    
    // Single drain loop - THE ONLY code that calls dequeueOutputBuffer
    private var drainJob: Job? = null
    
    // Runtime assertion - makes concurrent access impossible
    private val drainInProgress = AtomicBoolean(false)
    
    /**
     * Start recording. Creates encoder, muxer, starts single drain loop.
     */
    suspend fun startRecording(
        config: RecordingConfig,
        frameSource: ReceiveChannel<FrameData>
    ): Result<RecordingSession> = withContext(recordingDispatcher) {
        // State transition: Idle → Recording
        check(state.compareAndSet(State.Idle, State.Recording(config.sessionId))) {
            "Cannot start: not idle"
        }
        
        try {
            val encoder = createEncoder(config)
            val muxer = createMuxer(config.tempFile)
            
            // Start THE ONLY drain loop
            drainJob = scope.launch {
                drainLoop(encoder, muxer, config.sessionId)
            }
            
            // Start frame ingestion (feeds encoder input)
            scope.launch {
                ingestFrames(encoder, frameSource, config.sessionId)
            }
            
            log("STARTED sessionId=${config.sessionId}")
            Result.success(RecordingSession(config.sessionId))
            
        } catch (e: Exception) {
            state.set(State.Idle)
            Result.failure(e)
        }
    }
    
    /**
     * Stop recording. Signals EOS, waits for drain to complete, finalizes.
     */
    suspend fun stopRecording(): Result<Uri> = withContext(recordingDispatcher) {
        val currentState = state.get()
        check(currentState is State.Recording) { "Not recording" }
        
        // State transition: Recording → Stopping
        state.set(State.Stopping(currentState.sessionId))
        log("STOP_REQUESTED sessionId=${currentState.sessionId}")
        
        try {
            // 1. Close frame input (stop accepting new frames)
            closeFrameInput()
            
            // 2. Signal EOS to encoder
            signalEncoderEos()
            log("EOS_SIGNALED")
            
            // 3. Wait for drain loop to complete (it will see EOS and exit)
            drainJob?.join()
            log("DRAIN_COMPLETED")
            
            // 4. Stop muxer (exactly once, here)
            stopMuxer()
            log("MUXER_STOPPED")
            
            // 5. Release codec
            releaseEncoder()
            log("CODEC_RELEASED")
            
            // 6. Publish to MediaStore
            val uri = publishToMediaStore()
            log("MEDIASTORE_PUBLISHED uri=$uri")
            
            state.set(State.Idle)
            Result.success(uri)
            
        } catch (e: Exception) {
            // Cleanup and surface error
            cleanupFailedRecording()
            state.set(State.Idle)
            Result.failure(e)
        }
    }
    
    /**
     * THE ONLY drain loop. Single consumer of encoder output.
     */
    private suspend fun drainLoop(
        encoder: MediaCodec,
        muxer: MediaMuxer,
        sessionId: String
    ) {
        log("DRAIN_LOOP_STARTED sessionId=$sessionId drainLoopId=1")
        
        val bufferInfo = MediaCodec.BufferInfo()
        var trackIndex = -1
        var sawEos = false
        
        while (!sawEos && isActive) {
            // Runtime assertion: prove single-consumer
            check(drainInProgress.compareAndSet(false, true)) {
                "INVARIANT VIOLATION: Concurrent dequeue detected!"
            }
            
            try {
                val outputIndex = encoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                
                when {
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        trackIndex = muxer.addTrack(encoder.outputFormat)
                        muxer.start()
                        log("MUXER_STARTED track=$trackIndex")
                    }
                    outputIndex >= 0 -> {
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            encoder.releaseOutputBuffer(outputIndex, false)
                            continue
                        }
                        
                        val buffer = encoder.getOutputBuffer(outputIndex)
                        if (buffer != null && trackIndex >= 0) {
                            muxer.writeSampleData(trackIndex, buffer, bufferInfo)
                        }
                        encoder.releaseOutputBuffer(outputIndex, false)
                        
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
        
        log("DRAIN_LOOP_EXITED sessionId=$sessionId")
    }
    
    companion object {
        private const val TIMEOUT_US = 10_000L
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

## Part VII: Runtime Assertions (Seatbelt)

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

## Part VIII: Logging (Golden Trace)

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

## Part IX: Implementation Checklist

### Phase 1: Instrumentation (Do First)

- [ ] Add session-scoped file logging for recording timeline
- [ ] Add `RecordingEvent` enum and logging
- [ ] Add runtime invariant assertions (`drainInProgress`, `muxerStopped`)
- [ ] Capture logs that survive app crash

### Phase 2: Single Drain Loop (P0)

- [ ] Create `RecordingPipelineController` class
- [ ] Implement single `drainLoop()` as THE ONLY dequeue path
- [ ] Remove `drainEncoderFinal()` entirely
- [ ] Route all stop operations through state machine

### Phase 3: Stop Semantics (P0)

- [ ] Change stop to: close inputs → signal EOS → await drain → finalize
- [ ] Remove `cancel()` + second drain pattern
- [ ] Ensure muxer stop happens exactly once

### Phase 4: Atomic Publishing (P1)

- [ ] Implement `IS_PENDING` MediaStore pattern
- [ ] Handle failure: delete pending entry, surface error
- [ ] Verify: valid video visible in gallery, or nothing

### Phase 5: Verification

- [ ] Test 1: Record 2-3s → stop → save (expect: visible, playable)
- [ ] Test 2: Record 2-3s → stop quickly (<300ms) (expect: no crash)
- [ ] Verify: `drainLoopId` never duplicated
- [ ] Verify: Golden trace in logs

---

## Part X: Success Criteria

| Test | Expected Result |
|------|-----------------|
| Normal recording | Valid MP4, visible in gallery, correct duration |
| Quick stop (<300ms) | Either valid short video, or clean failure + user feedback |
| `drainLoopId` | Never more than 1 per recording |
| Dequeue calls | Always single-threaded (assertion never trips) |
| Muxer stop | Exactly once per recording |
| Crash recovery | Temp files cleaned up, no corrupt videos visible |

---

## Reference

- Surface Lease Pattern: `patches/SCOPECAM_ENGINE_WARM_GATE_DIRECTIVE.md`
- Native Frame Timestamps: `docs/PTS_SCR_PLUMBING.md`
- Architecture: `docs/architecture.md`

**This directive is BINDING. Non-compliance results in:**
- MediaCodec crashes (concurrent dequeue)
- Corrupt/invisible recordings
- User data loss
