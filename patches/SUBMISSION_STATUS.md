# Patch Submission Status

**From:** uvccamera-experimental
**To:** scopecam-engine
**Date:** 2026-01-13
**Updated:** 2026-01-13

---

## Current Status: CRITICAL BUG FIXES READY

Expert analysis revealed 6 critical bugs in libuvc that explain silent streaming failures. These fixes have been applied and build successfully.

**Previous Phase 0 patches were integrated by scopecam-engine, but the critical bugs discovered since then must be applied before device testing can succeed.**

---

## Critical Bug Fixes (NEW - Priority 1)

| Fix | Target | Description | Status |
|-----|--------|-------------|--------|
| Fix 1: Assert removal | `stream.c` | Replace production asserts with bounds checks | ✅ Complete |
| Fix 2: abstract_fmt | `stream.c` | Set abstract_fmt = 1 in ABS_FMT macro | ✅ Complete |
| Fix 3: MJPEG GUID | `stream.c` | Expand MJPEG GUID from 4 to 16 bytes | ✅ Complete |
| Fix 4: BY8 format | `stream.c` | Add BY8 to UNCOMPRESSED children | ✅ Complete |
| Fix 5: SCR parsing | `stream.c` | Fix SCR to read 6 bytes (both paths) | ✅ Complete |
| Fix 6: Interface lookup | `stream.c` | Search by bInterfaceNumber, not index | ✅ Complete |

### Why These Fixes Are Critical

The MJPEG GUID truncation alone causes format detection to fail:
1. Camera connects
2. Format negotiation attempts MJPEG GUID match
3. 4-byte GUID fails to match device's 16-byte GUID
4. Returns UVC_FRAME_FORMAT_UNKNOWN
5. `uvc_stream_start_bandwidth` exits early
6. Zero frames received

**Without Fix 3, streaming cannot start for MJPEG cameras.**

---

## Phase 0 Feature Patches (Previously Integrated)

| Patch | Code Status | Integration Status |
|-------|-------------|-------------------|
| `libuvc-pts-scr-plumbing.patch` | ✅ Complete | ✅ Integrated in scopecam-engine |
| `thread-priority.patch` | ✅ Complete | ✅ Integrated in scopecam-engine |

---

## Build Verification

```
BUILD SUCCESSFUL in 6s
28 actionable tasks: 8 executed, 20 up-to-date
```

All 6 bug fixes compile successfully with the NDK.

---

## Files Modified

All fixes are in a single file:
- `lib/src/main/jni/libuvc/src/stream.c`

### Line Numbers (after all fixes applied)

| Fix | Lines | Description |
|-----|-------|-------------|
| Fix 2 | 83-88 | ABS_FMT macro: abstract_fmt = 1 |
| Fix 4 | 101-103 | UNCOMPRESSED children includes BY8 |
| Fix 3 | 114-117 | MJPEG GUID: 16 bytes |
| Fix 5a | 766-779 | SCR bulk path: 6 bytes |
| Fix 5b | 914-928 | SCR ISO path: header_len >= 12 |
| Fix 1 | 944-958 | Bounds checks replace asserts |
| Fix 6 | 1497-1518 | Interface lookup loop |

---

## Next Steps for scopecam-engine

1. **Apply bug fixes** - Copy the updated `stream.c` or create a patch
2. **Rebuild APK** - `./gradlew :app:assembleQaDebug`
3. **Device testing** - Now streaming should actually work
4. **Report results** - Fill in PTS_RELIABILITY_REPORT.md

---

## Verification Checklist

Before device testing:

- [x] Build succeeds
- [x] No compiler warnings from changes
- [x] MJPEG GUID is exactly 16 bytes
- [x] abstract_fmt is 1 in ABS_FMT macro
- [x] BY8 is in UNCOMPRESSED children list
- [x] SCR parsing advances by 6 bytes (both paths)
- [x] Interface lookup uses search loop
- [x] No assert() calls remain in production paths

---

## Documentation

| Document | Status |
|----------|--------|
| `docs/PTS_SCR_PLUMBING.md` | ✅ Complete |
| `docs/THREAD_PRIORITY.md` | ✅ Complete |
| `docs/PTS_RELIABILITY_REPORT.md` | ⏳ Template (needs test data) |
| `docs/EXPECTED_USAGE.md` | ✅ Complete |
