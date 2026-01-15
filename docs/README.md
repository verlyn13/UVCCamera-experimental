# UVCCamera Documentation

This is a maintained fork of UVCCamera with enhanced ring buffer support for zero-copy GPU rendering.

**Project Role:** SANDBOX for testing UVC library improvements before promotion to scopecam-engine via patches.

---

## Quick Start

| If you want to... | Read this |
|-------------------|-----------|
| Understand the architecture | [architecture.md](./architecture.md) |
| Use the public API | [api-reference.md](./api-reference.md) |
| Integrate with an app | [ScopeCam-Integration-Guide.md](./ScopeCam-Integration-Guide.md) |
| Check current status | [status/IMPLEMENTATION-STATUS.md](./status/IMPLEMENTATION-STATUS.md) |
| Understand patch workflow | [PROMOTION_WORKFLOW.md](./PROMOTION_WORKFLOW.md) |

---

## Core Documentation

| Document | Description |
|----------|-------------|
| [architecture.md](./architecture.md) | System architecture, pipeline topology, frame routing, threading model, NativeSnapshot |
| [api-reference.md](./api-reference.md) | Public API reference with method signatures and usage examples |

---

## App Integration (scopecam-engine)

### Binding Directives

These directives define architectural contracts for the consumer application:

| Directive | Location | Content |
|-----------|----------|---------|
| **WARM Gate (R2)** | `../patches/SCOPECAM_ENGINE_WARM_GATE_DIRECTIVE.md` | Surface lease, FD truth, SurfaceLeaseController |
| **Video Recording (R3)** | `../patches/SCOPECAM_ENGINE_VIDEO_RECORDING_DIRECTIVE.md` | HOT gate, capture commit, RecordingCoordinator |

### Integration Resources

| Document | Description |
|----------|-------------|
| [ScopeCam-Integration-Guide.md](./ScopeCam-Integration-Guide.md) | Complete integration patterns including WARM state, recording, persistence |

### Key Patterns

| Pattern | Purpose |
|---------|---------|
| **NativeSnapshot** | Single-call state query (never infer from FD/ctrlBlock) |
| **SurfaceLeaseController** | Single owner of surface attach/detach |
| **RecordingCoordinator** | HOT gate + first-frame SLA |
| **RecordingPipelineController** | Single owner of MediaCodec/Muxer |
| **Capture Commit** | MediaStore + DB insert as transaction |

---

## Status & Progress

| Document | Description |
|----------|-------------|
| [status/IMPLEMENTATION-STATUS.md](./status/IMPLEMENTATION-STATUS.md) | Current phase progress, task tracking |
| [status/DEVIATIONS.md](./status/DEVIATIONS.md) | Deviations from planned approach |
| [PROMOTION_WORKFLOW.md](./PROMOTION_WORKFLOW.md) | Patch promotion process |

---

## Phase Documentation

| Document | Description |
|----------|-------------|
| [PHASE_0_COMPLETION.md](./PHASE_0_COMPLETION.md) | Phase 0 summary (PTS/SCR, thread priority) |
| [PHASE_1_PROGRESS.md](./PHASE_1_PROGRESS.md) | Phase 1 progress (GET_INFO, cache, empirical) |
| [PTS_SCR_PLUMBING.md](./PTS_SCR_PLUMBING.md) | PTS/SCR implementation details |
| [THREAD_PRIORITY.md](./THREAD_PRIORITY.md) | Thread priority implementation |
| [TASK_1.3_EMPIRICAL_INFERENCE_PLAN.md](./TASK_1.3_EMPIRICAL_INFERENCE_PLAN.md) | Empirical inference design |

---

## Implementation Details

| Document | Description |
|----------|-------------|
| [Phase4-Bidirectional-Fence-Implementation.md](./Phase4-Bidirectional-Fence-Implementation.md) | GPU/CPU fence synchronization |
| [Producer-Consumer-Handshake-Trace.md](./Producer-Consumer-Handshake-Trace.md) | Frame handoff trace between threads |

---

## Historical/Reference

| Document | Description |
|----------|-------------|
| [Native-Kotlin-Alignment-Checklist.md](./Native-Kotlin-Alignment-Checklist.md) | JNI contract verification checklist |
| [Native-Ground-Truth.md](./Native-Ground-Truth.md) | ScopeCam-specific integration context |
| [SafeUvcCameraManager-Audit-Feasibility-Report.md](./SafeUvcCameraManager-Audit-Feasibility-Report.md) | Kotlin wrapper feasibility analysis |

---

## Archive

Historical planning documents, bug reports, and superseded designs are preserved in [archive/](./archive/).

---

## Key Concepts

### Frame Routing

The conversion thread routes frames based on **consumer availability**:

```cpp
bool hasConsumer = surfaceReady || ringConsumerActive;

if (hasConsumer) {
    ring->unlockWriteBuffer();   // Commit frame
} else {
    ring->cancelWriteBuffer();   // Active drain
}
```

- `surfaceReady`: ANativeWindow display path active
- `ringConsumerActive`: Ring buffer mode with Kotlin GL consumer

### State Machine

| State | Description |
|-------|-------------|
| COLD | No USB streaming, preview thread stopped |
| WARM | USB streaming active, no display consumer (capture-only) |
| HOT | USB streaming + display consumer active |

### Recording Contract

Recording may start ONLY when:
```
previewState == HOT && surfaceAttached && !stagnant
```

---

## Cross-Project Boundary

```
┌─────────────────────────────────────────────────────────────────────┐
│  NATIVE (uvccamera) OWNS:             KOTLIN (scopecam) OWNS:       │
│  ├── USB session (FD after dup)       ├── Android lifecycle         │
│  ├── Preview pipeline                 ├── UI surfaces               │
│  ├── Frame production                 ├── Recording pipeline        │
│  ├── Ring buffer                      ├── MediaStore publishing     │
│  ├── Timestamps (PTS/SCR)             ├── DB persistence (Room)     │
│  └── WARM/HOT state machine           └── Gallery/reconciliation    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Build & Test

```bash
# Build AAR
./gradlew :lib:assembleRelease

# Publish to local Maven
./gradlew :lib:publishToMavenLocal

# Verify frame routing (after deployment)
adb logcat | grep -E "STATE_TRACE|RING_WRITE|latest="
```

---

*Last updated: 2026-01-14*
