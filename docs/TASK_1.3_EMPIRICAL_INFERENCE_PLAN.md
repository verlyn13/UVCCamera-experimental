# Task 1.3: Empirical Inference Engine - Implementation Plan

**Document Version:** 1.0
**Created:** 2026-01-13
**Status:** Planning Complete, Ready for Implementation
**Risk Level:** HIGH (USB bus stability, threading safety)

---

## Executive Summary

This plan implements a **production-grade Empirical Inference Engine** for UVC control discovery on non-compliant USB devices. The design addresses three critical gaps identified in the codebase audit:

1. **Infinite Wait Hazard** — `CTRL_TIMEOUT_MILLIS=0` causes deadlocks
2. **Volatility Gap** — Cache cleared on `uvc_close()`, forcing re-discovery
3. **Race Conditions** — No mutex on control operations during probe/UI interaction

---

## Dependency Graph

```
Phase 0 (Safety Foundation)
    │
    ├──► Phase 1A (BLACKLIST enum)
    │         │
    │         ├──► Phase 1B (cache entry metadata)
    │         │         │
    │         │         └──► Phase 1C (ctrl_mutex + probe_timeout)
    │         │                   │
    │         │                   ├──► Phase 2A (timestamp helper)
    │         │                   │         │
    │         │                   │         ├──► Phase 2B (cache entry helper)
    │         │                   │         │         │
    │         │                   │         │         └──► Phase 2C (empirical probe)
    │         │                   │         │                   │
    │         │                   │         │                   └──► Phase 3 (integration)
    │         │                   │         │                             │
    │         │                   │         │                             └──► Phase 4 (lifecycle)
    │         │                   │         │                                       │
    │         │                   │         │                                       └──► Phase 5 (JNI)
    │         │                   │         │                                                 │
    │         │                   │         │                                                 └──► Phase 6 (test)
```

---

## Phase 0: Safety Foundation (CRITICAL - DO FIRST)

### Objective
Replace the dangerous `CTRL_TIMEOUT_MILLIS=0` with a configurable, finite timeout.

### Files Modified
- `lib/src/main/jni/libuvc/src/ctrl.c`

### Changes

**Before:**
```c
#define CTRL_TIMEOUT_MILLIS 0
```

**After:**
```c
/** Default timeout for standard control transfers (non-probe operations) */
#define CTRL_TIMEOUT_MILLIS 1000

/** Timeout for empirical probe operations (more conservative) */
#define PROBE_TIMEOUT_MILLIS 500
```

### Rationale
- 1000ms is sufficient for compliant devices
- 500ms probe timeout prevents UI hangs during discovery
- Non-zero timeout ensures `libusb_control_transfer` eventually returns

### Verification
- Build succeeds
- Existing controls still respond on known-good hardware
- No behavioral change for compliant devices

---

## Phase 1A: Header Enhancement — BLACKLIST State

### Objective
Extend `uvc_ctrl_cap_source_t` to include a `BLACKLIST` state for permanently marking dangerous controls.

### Files Modified
- `lib/src/main/jni/libuvc/include/libuvc/libuvc.h`

### Changes

```c
/**
 * @brief Source of control capability information.
 * Extended to support a "Blacklisted" state for non-compliant hardware.
 * @ingroup ctrl
 */
typedef enum uvc_ctrl_cap_source {
    UVC_CAP_SOURCE_UNKNOWN   = 0,  // Initial state: Not yet probed
    UVC_CAP_SOURCE_GET_INFO  = 1,  // Verified via UVC 1.1/1.5 GET_INFO
    UVC_CAP_SOURCE_EMPIRICAL = 2,  // Inferred via No-Op GET/SET sequence
    UVC_CAP_SOURCE_FALLBACK  = 3,  // Failed probe; using safe defaults
    UVC_CAP_SOURCE_BLACKLIST = 4   // Probing caused STALL/TIMEOUT; never touch again
} uvc_ctrl_cap_source_t;
```

### State Machine Semantics

| State | Meaning | USB Bus Access |
|-------|---------|----------------|
| `UNKNOWN` | No data yet | Will probe |
| `GET_INFO` | UVC-compliant response | Trusted |
| `EMPIRICAL` | No-Op probe succeeded | Trusted |
| `FALLBACK` | Both failed; defaults assumed | Risky |
| `BLACKLIST` | Caused hang/crash; avoid | **Never** |

---

## Phase 1B: Header Enhancement — Cache Entry Metadata

### Objective
Extend `uvc_ctrl_cache_entry_t` with temporal and diagnostic metadata.

### Files Modified
- `lib/src/main/jni/libuvc/include/libuvc/libuvc_internal.h`

### Changes

```c
/**
 * @brief Professional-grade Control Cache Entry.
 * Optimized for thread safety and empirical inference tracking.
 */
typedef struct uvc_ctrl_cache_entry {
    uint8_t unit;                  // Terminal or Unit ID
    uint8_t ctrl;                  // Control Selector (CS)

    uvc_ctrl_caps_t caps;          // Bitfield: supports_get, supports_set, etc.
    uvc_ctrl_cap_source_t source;  // Provenance of this data

    // === Empirical Inference Metadata ===
    int64_t last_probe_time_ms;    // Timestamp to prevent rapid-fire re-probing
    uint8_t probe_attempts;        // Counter to detect "flaky" controls
    int16_t last_error;            // Last libusb error (e.g., LIBUSB_ERROR_PIPE)

    struct uvc_ctrl_cache_entry *next;
} uvc_ctrl_cache_entry_t;
```

### Field Rationale

| Field | Purpose |
|-------|---------|
| `last_probe_time_ms` | Enforce 50ms cooldown between probes |
| `probe_attempts` | Detect intermittent failures (>3 = blacklist candidate) |
| `last_error` | Diagnostic logging and hardware compatibility reports |

---

## Phase 1C: Header Enhancement — Device Handle Extension

### Objective
Add `ctrl_mutex` and `probe_timeout_ms` to `uvc_device_handle_t`.

### Files Modified
- `lib/src/main/jni/libuvc/include/libuvc/libuvc_internal.h`

### Changes

```c
/** Handle on an open UVC device */
struct uvc_device_handle {
    struct uvc_device *dev;
    struct uvc_device *prev, *next;
    struct libusb_device_handle *usb_devh;
    struct uvc_device_info *info;
    struct libusb_transfer *status_xfer;

    // === Phase 1 Task 1.3: Thread-Safe Control Discovery ===

    /** Guards ctrl_cache and serializes all control transfers during probing */
    pthread_mutex_t ctrl_mutex;

    /** Head of the Control Capability Cache (linked list) */
    uvc_ctrl_cache_entry_t *ctrl_cache;

    /** Configurable timeout for empirical probes (default: 500ms) */
    unsigned int probe_timeout_ms;

    // === Existing members ===
    pthread_mutex_t status_mutex;
    uint8_t status_buf[32];
    uvc_status_callback_t status_cb;
    void *status_user_ptr;
    uvc_button_callback_t button_cb;
    void *button_user_ptr;
    uint8_t reset_on_release_if;
};
```

---

## Phase 2A: Core Implementation — Timestamp Helper

### Objective
Provide a monotonic timestamp function for temporal guarding.

### Files Modified
- `lib/src/main/jni/libuvc/src/ctrl.c`

### Implementation

```c
#include <time.h>

/**
 * @brief Get current monotonic time in milliseconds.
 * Used for temporal backoff in empirical probing.
 */
static int64_t uvc_get_timestamp_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;  // Fallback if clock unavailable
    }
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
```

---

## Phase 2B: Core Implementation — Cache Entry Helper

### Objective
Thread-safe cache entry creation with mutex protection.

### Files Modified
- `lib/src/main/jni/libuvc/src/ctrl.c`

### Implementation

```c
/**
 * @brief Allocate and insert a new cache entry (thread-safe).
 * @pre Caller should NOT hold ctrl_mutex (this function acquires it).
 */
static uvc_ctrl_cache_entry_t* uvc_add_ctrl_cache_entry(
    uvc_device_handle_t *devh, uint8_t unit, uint8_t ctrl
) {
    uvc_ctrl_cache_entry_t *entry = calloc(1, sizeof(uvc_ctrl_cache_entry_t));
    if (!entry) {
        LOGE("Failed to allocate cache entry for unit=%u ctrl=%u", unit, ctrl);
        return NULL;
    }

    entry->unit = unit;
    entry->ctrl = ctrl;
    entry->source = UVC_CAP_SOURCE_UNKNOWN;
    entry->last_probe_time_ms = 0;
    entry->probe_attempts = 0;
    entry->last_error = 0;

    pthread_mutex_lock(&devh->ctrl_mutex);
    entry->next = devh->ctrl_cache;
    devh->ctrl_cache = entry;
    pthread_mutex_unlock(&devh->ctrl_mutex);

    LOGD("Created cache entry: unit=%u ctrl=%u", unit, ctrl);
    return entry;
}
```

---

## Phase 2C: Core Implementation — Empirical Probe Function

### Objective
Implement the No-Op probe protocol with strict timeout and mutex guarding.

### Files Modified
- `lib/src/main/jni/libuvc/src/ctrl.c`

### Implementation

```c
/** Maximum buffer size for any UVC control value */
#define MAX_CONTROL_VAL_LEN 64

/** Minimum cooldown between probes on the same control (ms) */
#define PROBE_COOLDOWN_MS 50

/**
 * @brief Performs empirical discovery of a control's capabilities.
 *
 * Protocol:
 * 1. Lock ctrl_mutex
 * 2. GET_CUR with strict timeout → validates "supports_get"
 * 3. SET_CUR(same value) → validates "supports_set" without side effects
 * 4. Update cache entry with UVC_CAP_SOURCE_EMPIRICAL
 *
 * @param devh Device handle
 * @param unit Terminal or Unit ID
 * @param ctrl Control Selector
 * @param entry Cache entry to populate (must be pre-allocated)
 * @return UVC_SUCCESS if GET succeeded; error code otherwise
 */
uvc_error_t uvc_probe_control_empirical(
    uvc_device_handle_t *devh,
    uint8_t unit,
    uint8_t ctrl,
    uvc_ctrl_cache_entry_t *entry
) {
    if (!devh || !entry) {
        return UVC_ERROR_INVALID_PARAM;
    }

    uvc_error_t ret;
    uint8_t data[MAX_CONTROL_VAL_LEN];
    int len;

    // 1. Thread Safety: Acquire control lock
    if (pthread_mutex_lock(&devh->ctrl_mutex) != 0) {
        return UVC_ERROR_IO;
    }

    // 2. Temporal Guard: Enforce cooldown
    int64_t now = uvc_get_timestamp_ms();
    if (entry->last_probe_time_ms > 0 &&
        (now - entry->last_probe_time_ms) < PROBE_COOLDOWN_MS) {
        LOGD("Probe cooldown active for unit=%u ctrl=%u", unit, ctrl);
        ret = UVC_ERROR_BUSY;
        goto release_and_exit;
    }

    // Initialize entry state
    entry->caps.supports_get = 0;
    entry->caps.supports_set = 0;
    entry->source = UVC_CAP_SOURCE_EMPIRICAL;
    entry->last_probe_time_ms = now;
    entry->probe_attempts++;

    // 3. Phase A: Empirical GET Discovery
    len = libusb_control_transfer(
        devh->usb_devh,
        REQ_TYPE_GET, UVC_GET_CUR,
        ctrl << 8,
        unit << 8,
        data, sizeof(data),
        devh->probe_timeout_ms
    );

    if (len < 0) {
        ret = (uvc_error_t)len;
        entry->last_error = (int16_t)len;

        if (ret == LIBUSB_ERROR_PIPE) {
            // STALL: Hardware explicitly rejects this control
            LOGW("Empirical GET_CUR STALL: unit=%u ctrl=%u → Blacklisting", unit, ctrl);
            entry->source = UVC_CAP_SOURCE_BLACKLIST;
        } else if (ret == LIBUSB_ERROR_TIMEOUT) {
            // TIMEOUT: Non-responsive; blacklist to prevent future hangs
            LOGE("Empirical GET_CUR TIMEOUT: unit=%u ctrl=%u → Blacklisting", unit, ctrl);
            entry->source = UVC_CAP_SOURCE_BLACKLIST;
        }
        goto release_and_exit;
    }

    // GET succeeded
    entry->caps.supports_get = 1;
    ret = UVC_SUCCESS;

    // 4. Phase B: Empirical SET Discovery (No-Op Write)
    // Write back exactly what we read → tests writability without state change
    int set_ret = libusb_control_transfer(
        devh->usb_devh,
        REQ_TYPE_SET, UVC_SET_CUR,
        ctrl << 8,
        unit << 8,
        data, len,  // Use exact length from GET_CUR
        devh->probe_timeout_ms
    );

    if (set_ret >= 0) {
        entry->caps.supports_set = 1;
        LOGI("Empirical probe SUCCESS: unit=%u ctrl=%u is R/W", unit, ctrl);
    } else {
        entry->caps.supports_set = 0;
        entry->last_error = (int16_t)set_ret;
        LOGW("Empirical probe: unit=%u ctrl=%u is READ-ONLY (SET failed: %d)",
             unit, ctrl, set_ret);
    }

release_and_exit:
    pthread_mutex_unlock(&devh->ctrl_mutex);
    return ret;
}
```

---

## Phase 3: Integration — Smart GET_INFO

### Objective
Refactor `uvc_get_info()` to implement the cache-first, empirical-fallback pattern.

### Files Modified
- `lib/src/main/jni/libuvc/src/ctrl.c`

### Implementation Strategy

1. **Rename** existing `uvc_get_info()` to `uvc_get_info_legacy()` (preserves backwards compat)
2. **Create** new `uvc_get_info()` with smart logic
3. **Call sequence:** Cache lookup → GET_INFO → Empirical fallback → Blacklist

### New Implementation

```c
/**
 * @brief Professional GET_INFO with cache-first and empirical fallback.
 *
 * Logic:
 * 1. Check cache → return immediately if VERIFIED/EMPIRICAL/BLACKLIST
 * 2. Attempt UVC GET_INFO (spec-compliant path)
 * 3. On soft failure → invoke empirical probe
 * 4. On hard failure → blacklist control
 */
uvc_error_t uvc_get_info(uvc_device_handle_t *devh, uint8_t unit, uint8_t ctrl,
                         uvc_ctrl_caps_t *caps, uvc_ctrl_cap_source_t *source) {
    if (!devh || !caps || !source) {
        return UVC_ERROR_INVALID_PARAM;
    }

    uvc_error_t ret;
    uvc_ctrl_cache_entry_t *entry = NULL;

    // === STEP 1: Cache Lookup ===
    entry = uvc_find_ctrl_cache(devh, unit, ctrl);
    if (entry && entry->source != UVC_CAP_SOURCE_UNKNOWN) {
        if (entry->source == UVC_CAP_SOURCE_BLACKLIST) {
            LOGD("GET_INFO: unit=%u ctrl=%u is BLACKLISTED", unit, ctrl);
            return UVC_ERROR_NOT_SUPPORTED;
        }
        *caps = entry->caps;
        *source = entry->source;
        LOGD("GET_INFO cache hit: unit=%u ctrl=%u source=%d", unit, ctrl, *source);
        return UVC_SUCCESS;
    }

    // === STEP 2: Create cache entry if needed ===
    if (!entry) {
        entry = uvc_add_ctrl_cache_entry(devh, unit, ctrl);
        if (!entry) {
            return UVC_ERROR_NO_MEM;
        }
    }

    // === STEP 3: Attempt UVC-Compliant GET_INFO ===
    uint8_t info_byte = 0;
    pthread_mutex_lock(&devh->ctrl_mutex);
    ret = libusb_control_transfer(
        devh->usb_devh,
        REQ_TYPE_GET, UVC_GET_INFO,
        ctrl << 8,
        unit << 8,
        &info_byte, 1,
        devh->probe_timeout_ms
    );
    pthread_mutex_unlock(&devh->ctrl_mutex);

    LOGD("GET_INFO transfer: unit=%u ctrl=%u ret=%d info=0x%02x",
         unit, ctrl, ret, info_byte);

    if (ret == 1) {
        // Success: Parse capability bits per UVC 1.5 Table 4-3
        entry->caps.supports_get = (info_byte & 0x01) ? 1 : 0;
        entry->caps.supports_set = (info_byte & 0x02) ? 1 : 0;
        entry->caps.disabled     = (info_byte & 0x04) ? 1 : 0;
        entry->caps.autoupdate   = (info_byte & 0x08) ? 1 : 0;
        entry->caps.asynchronous = (info_byte & 0x10) ? 1 : 0;
        entry->source = UVC_CAP_SOURCE_GET_INFO;

        *caps = entry->caps;
        *source = entry->source;

        LOGI("GET_INFO success: unit=%u ctrl=%u get=%d set=%d disabled=%d",
             unit, ctrl, caps->supports_get, caps->supports_set, caps->disabled);
        return UVC_SUCCESS;
    }

    // === STEP 4: Soft Failure → Empirical Probe ===
    if (ret == LIBUSB_ERROR_PIPE || ret == LIBUSB_ERROR_TIMEOUT) {
        LOGW("GET_INFO non-compliant (unit=%u ctrl=%u, err=%d). Starting empirical probe...",
             unit, ctrl, ret);

        ret = uvc_probe_control_empirical(devh, unit, ctrl, entry);

        if (ret == UVC_SUCCESS || entry->caps.supports_get) {
            *caps = entry->caps;
            *source = entry->source;
            return UVC_SUCCESS;
        }
    }

    // === STEP 5: Hard Failure → Blacklist ===
    entry->source = UVC_CAP_SOURCE_BLACKLIST;
    entry->last_error = (int16_t)ret;
    LOGE("GET_INFO hard failure: unit=%u ctrl=%u err=%d → Blacklisted", unit, ctrl, ret);

    return UVC_ERROR_NOT_SUPPORTED;
}
```

---

## Phase 4: Device Lifecycle Integration

### Objective
Initialize and destroy `ctrl_mutex` in device open/close.

### Files Modified
- `lib/src/main/jni/libuvc/src/device.c`

### Changes in `uvc_open()`

```c
// After allocating internal_devh:
internal_devh->ctrl_cache = NULL;
internal_devh->probe_timeout_ms = PROBE_TIMEOUT_MILLIS;  // Default: 500ms
pthread_mutex_init(&internal_devh->ctrl_mutex, NULL);
```

### Changes in `uvc_close()`

```c
// Before uvc_clear_ctrl_cache():
pthread_mutex_destroy(&devh->ctrl_mutex);
```

---

## Phase 5: JNI Persistence Bridge

### Objective
Design the interface for persisting cache data to Android storage.

### Architecture

```
┌─────────────────────┐
│  libuvc (C)         │
│  uvc_ctrl_cache     │
└─────────┬───────────┘
          │ JNI
          ▼
┌─────────────────────┐
│  UVCCamera.cpp      │
│  exportCacheToJSON()│
│  importCacheFromJSON│
└─────────┬───────────┘
          │ JNI
          ▼
┌─────────────────────┐
│  Kotlin/Java        │
│  SharedPreferences  │
│  or Room Database   │
└─────────────────────┘
```

### Identity Key Format

```
K(device) = VID:PID:Serial     (if Serial != NULL)
K(device) = VID:PID:BusPath    (if Serial == NULL)

Example: "1234:5678:ABC123" or "1234:5678:001-002"
```

### JSON Schema

```json
{
  "device_id": "1234:5678:ABC123",
  "timestamp": "2026-01-13T22:30:00Z",
  "controls": [
    {
      "unit": 1,
      "ctrl": 2,
      "supports_get": true,
      "supports_set": true,
      "source": "EMPIRICAL",
      "last_error": 0
    }
  ]
}
```

### JNI Method Signatures

```java
// In UVCCamera.java
public native String nativeExportControlCache();
public native void nativeImportControlCache(String json);
```

---

## Phase 6: Testing & Validation

### Test Scenarios

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| T1 | GET_INFO on compliant device | `source = GET_INFO` |
| T2 | GET_INFO timeout | Empirical probe triggers |
| T3 | Empirical GET succeeds, SET fails | `supports_set = 0` |
| T4 | Both GET and SET fail | `source = BLACKLIST` |
| T5 | Rapid-fire probe (< 50ms) | Returns `UVC_ERROR_BUSY` |
| T6 | Cache hit on second call | No USB transfer |
| T7 | Blacklisted control | Returns `UVC_ERROR_NOT_SUPPORTED` immediately |

### Verification Commands

```bash
# Build verification
./gradlew :lib:assembleDebug

# Logcat filter for probe activity
adb logcat -s UVCCamera:V libuvc:V | grep -E "(GET_INFO|Empirical|Blacklist)"
```

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Deadlock from mutex | `goto release_and_exit` pattern ensures unlock |
| USB bus corruption | Mutex serializes all control transfers |
| Infinite hang | Non-zero timeout (500ms probe, 1000ms standard) |
| Memory leak | `uvc_clear_ctrl_cache()` frees all entries |
| Flaky hardware | `probe_attempts` counter detects intermittent failures |

---

## Implementation Order (Recommended)

```
Day 1: Phase 0 + Phase 1A + Phase 1B + Phase 1C (Headers only, no logic changes)
       → Build verification, ensure no regressions

Day 2: Phase 2A + Phase 2B + Phase 4 (Helpers + lifecycle)
       → Mutex init/destroy working

Day 3: Phase 2C (Empirical probe function)
       → Unit test with known hardware

Day 4: Phase 3 (Integration)
       → Full integration test

Day 5: Phase 5 + Phase 6 (Persistence + validation)
       → End-to-end testing
```

---

## Appendix: Files to Modify

| File | Phase | Changes |
|------|-------|---------|
| `libuvc/src/ctrl.c` | 0, 2A, 2B, 2C, 3 | Timeout, helpers, probe, integration |
| `libuvc/include/libuvc/libuvc.h` | 1A | BLACKLIST enum |
| `libuvc/include/libuvc/libuvc_internal.h` | 1B, 1C | Cache entry, device handle |
| `libuvc/src/device.c` | 4 | Mutex lifecycle |
| `UVCCamera/UVCCamera.cpp` | 5 | JNI export/import |
| `UVCCamera/UVCCamera.h` | 5 | JNI method declarations |

---

## Success Criteria

1. **No deadlocks** on any hardware (verified via stress test)
2. **Cache hit rate > 95%** after initial discovery
3. **Zero USB hangs** on blacklisted controls
4. **Persistence** survives app restart
5. **Thread safety** verified via race condition tests
