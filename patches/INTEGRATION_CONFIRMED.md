# Integration Confirmation

**Date:** 2026-01-13
**Status:** ✅ PATCHES INTEGRATED INTO SCOPECAM-ENGINE

---

## Milestone Achieved

scopecam-engine has successfully applied all Phase 0 patches from uvccamera-experimental. A testable APK is now available.

---

## Integration Summary

### Patches Applied

| Patch | Target | Status |
|-------|--------|--------|
| `libuvc-pts-scr-plumbing.patch` | `third_party/libuvc/` | ✅ Applied |
| `thread-priority.patch` | `third_party/libuvc/` | ✅ Applied |

### Files Modified in scopecam-engine

**libuvc (3 files):**
- `libuvc.h` - Added PTS/SCR fields to `uvc_frame_t`
- `libuvc_internal.h` - Added validity tracking to stream handle
- `stream.c` - PTS/SCR parsing (7 locations) + thread priority boost

**Telemetry (2 files):**
- `StreamTelemetry.h` - Version 2→3, fields 37→41, PTS/SCR atomics
- `NativeTelemetry.kt` - Matching field indices and parsing

### Build Artifact

```
app/build/outputs/apk/qa/debug/app-qa-debug.apk (32 MB)
```

---

## Current Phase: Device Testing

The integration is complete. **Device testing is now the blocking activity.**

### Test 1: PTS/SCR Reliability

```bash
# Install APK
adb install -r app-qa-debug.apk

# Monitor PTS/SCR (while streaming)
adb logcat -s "libuvc/stream:I" | grep -E "(pts|scr)"
```

**Success criteria:**
- [ ] PTS present in ≥90% of frames
- [ ] PTS strictly monotonic (allowing wraparound)
- [ ] Delta ~3000 ticks at 30fps (90kHz clock)
- [ ] No garbage values

### Test 2: Thread Priority

```bash
adb logcat -s "libuvc/stream:I" | grep "thread priority"
```

**Expected output:**
```
UVC callback thread priority: prev=0, requested=-10, actual=-10, result=0, errno=0
```

---

## uvccamera-experimental Status Update

| Item | Previous Status | Current Status |
|------|-----------------|----------------|
| PTS/SCR patch | Submitted | ✅ Integrated |
| Thread priority patch | Submitted | ✅ Integrated |
| Device testing | Blocked | ⏳ In progress (scopecam-engine) |
| Phase 0 code | Complete | ✅ Promoted |

---

## Next Steps

1. **Device testing** - Run APK with USB camera, capture test results
2. **Fill PTS_RELIABILITY_REPORT.md** - Document actual test data
3. **Move patches to applied/** - In scopecam-engine: `patches/incoming/` → `patches/applied/`
4. **Phase 0 signoff** - Confirm all success criteria met

---

## Acknowledgment

uvccamera-experimental confirms receipt of integration notification from scopecam-engine.

The sandbox has fulfilled its Phase 0 obligations:
- ✅ Code implementation complete
- ✅ Patches created and documented
- ✅ Patches accepted by scopecam-engine
- ⏳ Awaiting device test results

**uvccamera-experimental enters observation mode for Phase 0.**

Any issues discovered during device testing should be reported back for patch revision if needed.
