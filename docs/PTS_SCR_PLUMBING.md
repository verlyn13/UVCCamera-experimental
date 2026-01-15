# PTS/SCR Timestamp Plumbing

**Status:** Implemented (Phase 0, TARGETED-002)
**Date:** 2026-01-13

## Summary

This change connects the PTS (Presentation Time Stamp) and SCR (Source Clock Reference) values
that are already being extracted from UVC payload headers to the `uvc_frame_t` structure, making
them available to frame consumers.

## USB Video Class 1.5 Specification

Per the UVC 1.5 spec (Section 2.4.3.3):
- **PTS**: 32-bit field representing the source clock time at which the frame was captured
  - Units: 90kHz clock ticks (same as MPEG-2 PTS)
  - Present when `UVC_STREAM_PTS` bit is set in header
- **SCR**: 32-bit field representing the device's source clock reference
  - Units: Device-specific (typically USB SOF-based)
  - Present when `UVC_STREAM_SCR` bit is set in header

## Files Changed

| File | Change |
|------|--------|
| `libuvc/include/libuvc/libuvc.h` | Added `capture_time_pts`, `capture_time_scr`, and validity flags to `uvc_frame_t` |
| `libuvc/include/libuvc/libuvc_internal.h` | Added `pts_valid`, `scr_valid` tracking to stream handle |
| `libuvc/src/stream.c` | Set validity flags during PTS/SCR parsing; populate frame fields in `_uvc_populate_frame` |

## API Changes

### uvc_frame_t Structure (Additive)

```c
typedef struct uvc_frame {
    // ... existing fields ...

    /** Presentation Time Stamp from UVC payload header (USB Video Class 1.5 spec)
     * Valid only when capture_time_pts_valid is non-zero.
     * Units: 90kHz clock ticks (same as MPEG-2 PTS) */
    uint32_t capture_time_pts;

    /** Source Clock Reference from UVC payload header (USB Video Class 1.5 spec)
     * Valid only when capture_time_scr_valid is non-zero.
     * Units: device-specific clock (typically USB SOF-based) */
    uint32_t capture_time_scr;

    /** Non-zero if capture_time_pts contains valid data from the device */
    uint8_t capture_time_pts_valid;

    /** Non-zero if capture_time_scr contains valid data from the device */
    uint8_t capture_time_scr_valid;

    // ... existing fields ...
} uvc_frame_t;
```

## Usage Example

```c
void on_frame(uvc_frame_t* frame, void* user_ptr) {
    if (frame->capture_time_pts_valid) {
        uint32_t pts = frame->capture_time_pts;
        // PTS available - use for A/V sync, frame timing, etc.
        // Note: PTS is in 90kHz units, so divide by 90000 for seconds
        double pts_seconds = pts / 90000.0;
    }

    if (frame->capture_time_scr_valid) {
        uint32_t scr = frame->capture_time_scr;
        // SCR available - useful for clock sync with device
    }
}
```

## Important Notes

1. **Validity Flags**: Always check `capture_time_pts_valid` and `capture_time_scr_valid` before
   using the timestamp values. Not all cameras provide these timestamps.

2. **Wraparound**: PTS/SCR are 32-bit values that wrap around. At 90kHz, PTS wraps every ~13.25 hours.

3. **Not All Cameras Support**: Many USB cameras do not provide valid PTS/SCR data. Testing is
   required to verify which cameras provide reliable timestamps.

4. **Thread Safety**: These fields are populated under the callback mutex lock and are safe to
   read within the frame callback.

## Breaking Changes

None. The new fields are additive to the existing `uvc_frame_t` structure.

## Testing Required

Before promoting this patch to scopecam-engine, verify:
- [ ] PTS monotonicity (always increasing within wrap window)
- [ ] Consistency with expected frame rate
- [ ] Not garbage values (0x00000000 or 0xFFFFFFFF)
- [ ] Behavior with 2-3 different USB cameras

See `PTS_RELIABILITY_REPORT.md` for detailed test results.

## ADR Reference

Implements TARGETED-002 from ARCH-DECISIONS-001-R1.
