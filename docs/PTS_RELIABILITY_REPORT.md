# PTS/SCR Reliability Testing Report

**Status:** ⏳ AWAITING DEVICE TESTING
**Date:** 2026-01-13
**Tester:** _____________

---

> **ACTION REQUIRED:** This template must be filled in with actual test results
> from USB camera hardware before patches can be submitted to scopecam-engine.
>
> See `patches/SUBMISSION_STATUS.md` for testing instructions.

---

## Test Procedure

For each camera, perform the following tests:

### 1. Basic Availability Test
```bash
# Run the test app, stream for 30 seconds at 1080p30
# Log the following for each frame:
# - Frame sequence number
# - capture_time_pts_valid
# - capture_time_pts value (hex)
# - capture_time_scr_valid
# - capture_time_scr value (hex)
```

### 2. Monotonicity Test
```bash
# Verify that PTS values strictly increase (allowing for wraparound)
# Expected: pts[n+1] > pts[n] OR (pts[n+1] < pts[n] AND pts[n] > 0xF0000000)
```

### 3. Frame Rate Consistency Test
```bash
# Calculate delta between consecutive PTS values
# Expected for 30fps: delta ~= 3000 (90000 / 30)
# Expected for 60fps: delta ~= 1500 (90000 / 60)
# Allow +/- 10% variance
```

### 4. Long-Running Stability Test
```bash
# Stream for 10 minutes, verify:
# - No sudden jumps in PTS (except wraparound)
# - No sustained periods of invalid PTS
# - SCR continues to increment
```

---

## Camera Test Results

### Camera 1: ________________

| Parameter | Value |
|-----------|-------|
| **Vendor ID** | 0x____ |
| **Product ID** | 0x____ |
| **Model** | ________________ |
| **Resolution** | ________________ |
| **Frame Rate** | ________________ |

#### Availability
| Metric | Result |
|--------|--------|
| PTS Present | [ ] Yes / [ ] No |
| SCR Present | [ ] Yes / [ ] No |
| PTS Valid Rate | ____% |
| SCR Valid Rate | ____% |

#### Monotonicity
| Metric | Result |
|--------|--------|
| Total Frames | ________ |
| Monotonic Violations | ________ |
| Result | [ ] PASS / [ ] FAIL |

#### Frame Rate Consistency
| Metric | Result |
|--------|--------|
| Expected Delta (90kHz ticks) | ________ |
| Measured Mean Delta | ________ |
| Measured Std Dev | ________ |
| Within 10% Tolerance | [ ] PASS / [ ] FAIL |

#### Long-Running Stability
| Metric | Result |
|--------|--------|
| Test Duration | ________ min |
| PTS Gaps Detected | ________ |
| Unexpected Jumps | ________ |
| Result | [ ] PASS / [ ] FAIL |

#### Sample Log
```
seq=0001 pts_valid=1 pts=0x00001234 scr_valid=1 scr=0x00005678
seq=0002 pts_valid=1 pts=0x00001D5E scr_valid=1 scr=0x00005700
...
```

---

### Camera 2: ________________

(Copy template from Camera 1)

---

### Camera 3: ________________

(Copy template from Camera 1)

---

## Summary

| Camera | PTS Available | PTS Reliable | SCR Available | SCR Reliable | Recommendation |
|--------|---------------|--------------|---------------|--------------|----------------|
| Camera 1 | | | | | |
| Camera 2 | | | | | |
| Camera 3 | | | | | |

## Conclusions

_Document overall findings and recommendations for scopecam-engine integration._

## Test Environment

| Component | Version |
|-----------|---------|
| Android Version | |
| Device Model | |
| NDK Version | |
| libuvc Git SHA | |

---

**Note:** This report is required before promoting the PTS/SCR plumbing patch to scopecam-engine.
