# Thread Priority Testing

**Status:** Implemented (Phase 0, DECISION-007)
**Date:** 2026-01-13

## Summary

This change adds thread priority boosting to the UVC callback thread to improve real-time frame
delivery performance on Android.

## Implementation

### Priority Setting

```c
// At the start of _uvc_user_caller (callback thread):
int result = setpriority(PRIO_PROCESS, 0, -10);
```

### Parameters

- **PRIO_PROCESS** with tid=0: Sets the calling thread's priority (not the entire process)
- **Nice value -10**: High priority without requiring CAP_SYS_NICE capability
  - Nice range: -20 (highest) to 19 (lowest)
  - Default is 0
  - -10 provides significant boost while staying within unprivileged bounds

### Logging

The implementation logs priority changes for verification:
```
UVC callback thread priority: prev=%d, requested=-10, actual=%d, result=%d, errno=%d
```

## Files Changed

| File | Change |
|------|--------|
| `libuvc/src/stream.c` | Added setpriority call in `_uvc_user_caller` thread function |

## Expected Results

### Success Case
```
UVC callback thread priority: prev=0, requested=-10, actual=-10, result=0, errno=0
```

### Partial Success (Common on Android)
```
UVC callback thread priority: prev=0, requested=-10, actual=-5, result=0, errno=0
```
Note: Android may clamp the effective priority based on process state.

### Failure Case
```
UVC callback thread priority: prev=0, requested=-10, actual=0, result=-1, errno=13
Failed to boost thread priority (may need CAP_SYS_NICE): errno=13
```
Note: errno=13 is EACCES (permission denied). The app continues to work at normal priority.

## Android-Specific Notes

1. **No CAP_SYS_NICE Required**: Setting nice value to -10 typically works without special
   permissions on Android, as apps can boost their own threads within limits.

2. **Effective Priority May Differ**: Android's scheduler may adjust the effective priority
   based on foreground/background state and power management.

3. **Testing Required**: Verify actual priority achieved on target devices, as behavior
   varies by Android version and OEM customization.

## Testing Required

Before promoting this patch to scopecam-engine:

1. **Log Analysis**: Verify priority change is logged correctly on device startup
2. **Effective Priority**: Confirm `actual` priority matches or approaches requested
3. **Performance Impact**: Measure frame delivery latency with and without priority boost
4. **Multiple Devices**: Test on different Android versions/OEMs

## Breaking Changes

None. The priority boost is additive and fails gracefully if permission is denied.

## ADR Reference

Implements DECISION-007 from ARCH-DECISIONS-001-R1.
