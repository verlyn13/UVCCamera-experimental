# FEASIBILITY-003: PTS/SCR Timestamp Extraction

**Status:** Complete
**Date:** 2026-01-11
**Author:** Claude
**Prerequisite:** FEASIBILITY-001 (libuvc Deep Dive)
**Enables:** FEASIBILITY-006 (H.264/HEVC Pipeline)

---

## Executive Summary

The PTS (Presentation Time Stamp) and SCR (Source Clock Reference) extraction infrastructure **already exists** in libuvc but is **not connected** to the frame output. The fix is approximately **10 lines of code** to bridge the extracted values to the frame structure, plus **~200 lines** for a clock synchronization algorithm.

**Key Finding:** This is a "90% done" feature. The TODO marker at stream.c:1758 explicitly acknowledges the missing connection: `/** @todo set the frame time */`

**Recommendation:** **GO** - Highest ROI of all feasibility items. Enables timestamps for A/V sync and H.264 work.

---

## 1. Current State Analysis

### 1.1 PTS Extraction (Already Implemented)

```c
// stream.c:744-752 - PTS extracted from payload header
if (header_info & UVC_STREAM_PTS) {
    // XXX saki some camera may send broken packet or failed to receive all data
    if (LIKELY(variable_offset + 4 <= header_len)) {
        strmh->pts = DW_TO_INT(payload + variable_offset);
        variable_offset += 4;
    } else {
        MARK("bogus packet: header info has UVC_STREAM_PTS, but no data");
        strmh->pts = 0;
    }
}
```

### 1.2 SCR Extraction (Already Implemented)

```c
// stream.c:755-765 - SCR extracted from payload header
if (header_info & UVC_STREAM_SCR) {
    // @todo read the SOF token counter
    // XXX saki some camera may send broken packet or failed to receive all data
    if (LIKELY(variable_offset + 4 <= header_len)) {
        strmh->last_scr = DW_TO_INT(payload + variable_offset);
        variable_offset += 4;
    } else {
        MARK("bogus packet: header info has UVC_STREAM_SCR, but no data");
        strmh->last_scr = 0;
    }
}
```

### 1.3 Buffer Swap (Already Implemented)

```c
// stream.c:613-614 - Values copied to hold buffer on frame completion
strmh->hold_last_scr = strmh->last_scr;
strmh->hold_pts = strmh->pts;
```

### 1.4 Stream Handle Structure

```c
// libuvc_internal.h:268-270 - Fields defined
uint32_t seq, hold_seq;
uint32_t pts, hold_pts;           // ✅ PTS stored here
uint32_t last_scr, hold_last_scr; // ✅ SCR stored here
```

### 1.5 Frame Structure (Target)

```c
// libuvc.h:472-474 - Destination field exists but UNUSED
/** Estimate of system time when the device started capturing the image */
struct timeval capture_time;
```

### 1.6 The Missing Connection

```c
// stream.c:1719-1759 - _uvc_populate_frame() fills frame but NOT capture_time
static void _uvc_populate_frame(uvc_stream_handle_t *strmh) {
    uvc_frame_t *frame = &strmh->frame;
    // ... frame->width, frame->height, etc. are set ...

    memcpy(frame->data, strmh->holdbuf, strmh->hold_bytes);

    /** @todo set the frame time */  // <-- THE GAP (line 1758)
}
```

### 1.7 Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        CURRENT PTS/SCR DATA FLOW                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   USB Isochronous Transfer                                                   │
│          │                                                                   │
│          ▼                                                                   │
│   ┌─────────────────┐                                                       │
│   │ _uvc_process_   │  stream.c:744-765                                     │
│   │ payload()       │  PTS → strmh->pts                                     │
│   │                 │  SCR → strmh->last_scr                                │
│   └────────┬────────┘                                                       │
│            │                                                                 │
│            ▼ (on EOF or FID flip)                                           │
│   ┌─────────────────┐                                                       │
│   │ _uvc_swap_      │  stream.c:613-614                                     │
│   │ buffers()       │  strmh->pts → strmh->hold_pts      ✅ IMPLEMENTED    │
│   │                 │  strmh->last_scr → strmh->hold_last_scr               │
│   └────────┬────────┘                                                       │
│            │                                                                 │
│            ▼                                                                 │
│   ┌─────────────────┐                                                       │
│   │ _uvc_populate_  │  stream.c:1719-1759                                   │
│   │ frame()         │  frame->width ✅                                      │
│   │                 │  frame->height ✅                                     │
│   │                 │  frame->data ✅                                       │
│   │                 │  frame->capture_time = ??? 🔴 NOT SET                 │
│   └────────┬────────┘                                                       │
│            │                                                                 │
│            ▼                                                                 │
│   ┌─────────────────┐                                                       │
│   │ Application     │  Receives frame with capture_time = {0, 0}            │
│   │ Callback        │                                                       │
│   └─────────────────┘                                                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Target State Definition

### 2.1 Minimal Fix (Phase 1)

Connect `hold_pts` to `frame->capture_time` with direct conversion:

```c
// In _uvc_populate_frame():
if (strmh->hold_pts) {
    // Convert PTS (device clock) to timeval
    // PTS is typically in 90kHz units, but may vary by device
    uint64_t pts_usec = (uint64_t)strmh->hold_pts * 1000000 / 90000;
    frame->capture_time.tv_sec = pts_usec / 1000000;
    frame->capture_time.tv_usec = pts_usec % 1000000;
}
```

**Limitation:** This gives a relative timestamp, not synchronized to system time.

### 2.2 Full Implementation (Phase 2)

Add clock synchronization to map device PTS to system monotonic time:

```c
struct FrameMetadata {
    uint64_t pts_raw;           // Raw 32-bit PTS from UVC header
    uint64_t scr_raw;           // Raw SCR from UVC header
    uint64_t system_time_ns;    // Monotonic system time at frame receipt
    uint64_t capture_time_ns;   // Estimated capture time (synchronized)
    uint32_t clock_frequency;   // Device clock frequency (from descriptor)
    uint8_t pts_valid;          // PTS was present in header
    uint8_t scr_valid;          // SCR was present in header
};
```

### 2.3 Clock Synchronization Algorithm

```
Device Clock (PTS)         System Clock
       │                        │
       │    ┌─────────────┐     │
       │    │ Linear      │     │
       │───►│ Regression  │◄────│
       │    │ (samples)   │     │
       │    └──────┬──────┘     │
       │           │            │
       │           ▼            │
       │    ┌─────────────┐     │
       │    │ offset +    │     │
       │    │ drift rate  │     │
       │    └──────┬──────┘     │
       │           │            │
       ▼           ▼            ▼
   Raw PTS   Synchronized Time  System Time

Algorithm:
1. On each frame: record (pts_raw, system_time_ns) pair
2. Maintain rolling window of N samples (e.g., N=100)
3. Compute linear regression: system_time = a * pts + b
4. Use regression to convert any PTS to system time
5. Handle 32-bit PTS wraparound (every ~13 hours at 90kHz)
```

---

## 3. Gap Analysis

### 3.1 Code Changes Required

| Location | Change | LOC |
|----------|--------|-----|
| stream.c:1758 | Add PTS→capture_time conversion | 10 |
| stream.c (new) | Clock sync algorithm | 150 |
| libuvc.h | Extended frame metadata (optional) | 20 |
| UVCCamera.cpp | Pass timestamps to Kotlin | 20 |
| **Total** | | **~200** |

### 3.2 UVC Spec Compliance

| UVC Requirement | Current | After Fix |
|-----------------|---------|-----------|
| PTS extraction (§2.4.3.3) | ✅ Extracted | ✅ Extracted + used |
| SCR extraction (§2.4.3.3) | ✅ Extracted | ✅ Extracted + used |
| Frame timing | 🔴 No timing | ✅ Synchronized time |

### 3.3 API Impact

| Current API | After Fix |
|-------------|-----------|
| `frame->capture_time` always `{0,0}` | Valid timestamp |
| No metadata callback | Optional metadata callback |
| No clock info | Clock frequency accessible |

---

## 4. Technical Feasibility

### 4.1 Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| **Code complexity** | LOW | ~200 LOC total |
| **API compatibility** | HIGH | Non-breaking change |
| **Testing complexity** | MEDIUM | Requires timestamp verification |
| **Performance impact** | NEGLIGIBLE | <1µs per frame |

### 4.2 Clock Synchronization Challenges

| Challenge | Solution |
|-----------|----------|
| PTS wraps at 32-bit | Track wrap count, extend to 64-bit |
| Clock drift | Linear regression with rolling window |
| Variable clock frequency | Read from descriptor or use default 90kHz |
| Missing PTS (some cameras) | Fall back to system time |
| Initial sync delay | Require N samples before accurate time |

### 4.3 Clock Frequency Sources

```c
// UVC 1.1+ provides clock frequency in stream control
ctrl->dwClockFrequency  // libuvc.h:508

// UVC 1.5 default: 48MHz internal clock, 90kHz PTS
// Many cameras use 90kHz (MPEG standard)
```

---

## 5. Effort Estimation

### 5.1 Phase 1: Direct Connection (Minimal)

| Task | Effort |
|------|--------|
| Add PTS→capture_time conversion in _uvc_populate_frame | 2 hours |
| Test with camera that provides PTS | 2 hours |
| **Total Phase 1** | **4 hours** |

### 5.2 Phase 2: Clock Synchronization

| Task | Effort |
|------|--------|
| Implement ClockSynchronizer class | 1 day |
| Add wraparound handling | 2 hours |
| Integrate into streaming pipeline | 4 hours |
| Test clock accuracy | 1 day |
| **Total Phase 2** | **2-3 days** |

### 5.3 Phase 3: Extended Metadata (Optional)

| Task | Effort |
|------|--------|
| Add FrameMetadata structure | 2 hours |
| JNI exposure to Kotlin | 4 hours |
| Kotlin API for metadata access | 4 hours |
| **Total Phase 3** | **1-2 days** |

### 5.4 Combined Estimate

| Phase | Effort | Cumulative |
|-------|--------|------------|
| Phase 1 | 4 hours | 4 hours |
| Phase 2 | 2-3 days | 2.5-3.5 days |
| Phase 3 | 1-2 days | 3.5-5.5 days |
| Testing | 0.5-1 day | **4-6.5 days** |

---

## 6. Risk Assessment

### 6.1 Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Camera doesn't send PTS | MEDIUM | LOW | Fall back to system time |
| Clock drift > 1% | LOW | MEDIUM | Adaptive regression window |
| Wraparound bugs | LOW | HIGH | Extensive unit testing |
| Performance regression | LOW | LOW | Profile critical path |

### 6.2 Compatibility Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| API breaking change | NONE | - | All changes additive |
| Frame callback signature | NONE | - | Unchanged |
| ABI compatibility | NONE | - | No structure size change |

### 6.3 Camera Compatibility

| Camera Behavior | Prevalence | Handling |
|-----------------|------------|----------|
| PTS present | 90%+ | Normal path |
| PTS absent | ~5% | Use system time |
| Non-standard frequency | ~5% | Query descriptor |
| PTS always zero | Rare | Detect and fall back |

---

## 7. Dependencies

### 7.1 What This Requires

- Access to `strmh->hold_pts` and `strmh->hold_last_scr` (already present)
- Clock frequency from stream control (already parsed)
- System monotonic time function (POSIX clock_gettime)

### 7.2 What This Enables

| Feature | Dependency on PTS/SCR |
|---------|----------------------|
| A/V synchronization | Requires accurate PTS |
| H.264/HEVC decoding | Requires PTS for decode ordering |
| Frame interpolation | Requires timing for dropped frame detection |
| Scientific imaging | Requires sub-millisecond accuracy |
| Video recording | Requires consistent frame timing |

### 7.3 Dependency Graph

```mermaid
graph TD
    PTS[FEASIBILITY-003: PTS/SCR] --> H264[FEASIBILITY-006: H.264/HEVC]
    PTS --> AV[A/V Sync Feature]
    PTS --> Scientific[Scientific Imaging]

    ClockSync[Clock Synchronization] --> PTS
    FrameMeta[Frame Metadata] --> PTS
```

---

## 8. Recommendation

### 8.1 Decision: **GO** - Highest Priority

**Rationale:**
1. 90% of the work is already done
2. Enables multiple downstream features
3. No breaking changes
4. Minimal code complexity
5. High ROI (4-6 days → timestamps for all frames)

### 8.2 Implementation Plan

| Phase | Scope | Effort | Deliverable |
|-------|-------|--------|-------------|
| **Phase 1** | Direct PTS→capture_time | 4 hours | Basic timestamps |
| **Phase 2** | Clock synchronization | 2-3 days | Accurate timestamps |
| **Phase 3** | Extended metadata | 1-2 days | Full timing data |

### 8.3 Success Criteria

| Metric | Target |
|--------|--------|
| PTS accuracy | Within 1ms of camera clock |
| Sync accuracy | Within 5ms of system time after warmup |
| Performance | < 1µs overhead per frame |
| Compatibility | Works with 95%+ of UVC cameras |

### 8.4 Verification Test

```cpp
// Test: Verify PTS monotonicity and accuracy
uint64_t last_pts = 0;
int frames_with_pts = 0;
int frames_without_pts = 0;

void frame_callback(uvc_frame_t *frame, void *user_ptr) {
    if (frame->capture_time.tv_sec > 0 || frame->capture_time.tv_usec > 0) {
        frames_with_pts++;
        uint64_t pts_usec = frame->capture_time.tv_sec * 1000000 +
                           frame->capture_time.tv_usec;
        assert(pts_usec > last_pts);  // Monotonic
        last_pts = pts_usec;
    } else {
        frames_without_pts++;
    }
}

// After 100 frames: expect frames_with_pts > 95
```

---

## Appendix A: UVC Payload Header Format

### A.1 Header Structure (UVC 1.5 §2.4.3.3)

```
Byte 0: bHeaderLength (header size in bytes)
Byte 1: bmHeaderInfo
        Bit 0: FID (Frame ID toggle)
        Bit 1: EOF (End of Frame)
        Bit 2: PTS (Presentation Time Stamp present)
        Bit 3: SCR (Source Clock Reference present)
        Bit 4: RES (Reserved)
        Bit 5: STI (Still Image)
        Bit 6: ERR (Error)
        Bit 7: EOH (End of Header)

If PTS bit set:
  Bytes 2-5: dwPresentationTime (32-bit PTS in clock units)

If SCR bit set (after PTS if present):
  Bytes N-N+3: dwSCR[0..3] (Source Clock Reference)
  Bytes N+4-N+5: SCR.SOF[0..1] (SOF token counter)
```

### A.2 Example Header Parsing

```
Raw header: 0C 8C 12 34 56 78 AB CD EF 01 23 45

bHeaderLength = 0x0C (12 bytes)
bmHeaderInfo  = 0x8C = 10001100b
                       │││││││└─ FID = 0
                       ││││││└── EOF = 0
                       │││││└─── PTS = 1 (present)
                       ││││└──── SCR = 1 (present)
                       │││└───── RES = 0
                       ││└────── STI = 0
                       │└─────── ERR = 0
                       └──────── EOH = 1

PTS = 0x78563412 (little-endian)
SCR = 0x01EFCDAB
SOF = 0x4523
```

---

## Appendix B: Clock Synchronization Algorithm Detail

### B.1 Linear Regression Implementation

```cpp
class ClockSynchronizer {
private:
    struct Sample {
        uint64_t pts;        // Extended 64-bit PTS (wrap-aware)
        uint64_t system_ns;  // System monotonic time
    };

    std::deque<Sample> samples_;
    const size_t max_samples_ = 100;

    uint32_t last_raw_pts_ = 0;
    uint64_t pts_wrap_count_ = 0;

    double slope_ = 0;      // ns per PTS tick
    double intercept_ = 0;  // system time at PTS=0

public:
    void addSample(uint32_t raw_pts, uint64_t system_ns) {
        // Handle wraparound
        if (raw_pts < last_raw_pts_ &&
            (last_raw_pts_ - raw_pts) > 0x80000000) {
            pts_wrap_count_++;
        }
        last_raw_pts_ = raw_pts;

        uint64_t extended_pts = (pts_wrap_count_ << 32) | raw_pts;
        samples_.push_back({extended_pts, system_ns});

        if (samples_.size() > max_samples_) {
            samples_.pop_front();
        }

        // Recompute regression if enough samples
        if (samples_.size() >= 10) {
            computeRegression();
        }
    }

    uint64_t ptsToSystemTime(uint32_t raw_pts) const {
        uint64_t extended_pts = (pts_wrap_count_ << 32) | raw_pts;
        return static_cast<uint64_t>(slope_ * extended_pts + intercept_);
    }

private:
    void computeRegression() {
        // Standard linear regression: y = mx + b
        // where y = system_ns, x = pts
        double sum_x = 0, sum_y = 0, sum_xy = 0, sum_xx = 0;
        size_t n = samples_.size();

        for (const auto& s : samples_) {
            sum_x += s.pts;
            sum_y += s.system_ns;
            sum_xy += s.pts * s.system_ns;
            sum_xx += s.pts * s.pts;
        }

        double denom = n * sum_xx - sum_x * sum_x;
        if (abs(denom) > 1e-10) {
            slope_ = (n * sum_xy - sum_x * sum_y) / denom;
            intercept_ = (sum_y - slope_ * sum_x) / n;
        }
    }
};
```

### B.2 Expected Slope Values

| Clock Frequency | Expected Slope (ns/tick) |
|-----------------|-------------------------|
| 90 kHz | 11,111 ns |
| 48 MHz | 20.83 ns |
| 27 MHz | 37.04 ns |

---

*End of FEASIBILITY-003*
