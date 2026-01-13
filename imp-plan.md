# Implementation Plan for ARCH-DECISIONS-001-R1

**Status:** Updated with concrete two-repo mechanics
**Last Updated:** 2026-01-12
**Repos:**
- **uvccamera-experimental** (`~/Development/personal/UVCCamera-experimental/`): libuvc source, ndk-build
- **scopecam-engine** (`~/Development/personal/scopecam-engine/`): Kotlin + C++20 CMake, consumes prebuilt .so

---

## Repo Split Reality

| Component | Lives In | Build System |
|-----------|----------|--------------|
| libuvc source (stream.c, device.c, ctrl.c) | uvccamera-experimental | ndk-build |
| libusb, libjpeg-turbo | uvccamera-experimental | ndk-build |
| JNI bridge (UVCCamera.cpp, UVCPreview.cpp) | uvccamera-experimental | ndk-build |
| Prebuilt .so files | scopecam-engine/nativecode/src/main/libs/ | N/A (copied) |
| Engine native (FrameBufferRing, telemetry) | scopecam-engine/nativecode/ | CMake (C++20) |
| Kotlin API + Recovery FSM | scopecam-engine/camera-platform/ | Gradle |

**Critical Path:** Changes to libuvc internals require:
1. Edit in uvccamera-experimental
2. Build with ndk-build
3. Copy .so to scopecam-engine
4. Verify via runtime build ID

---

## Phase 0-Pre: Integration Infrastructure (BLOCKER)

Before any feature work, establish deterministic sync between repos.

### 0-Pre.1: Runtime Build ID (Prove Which Binary Runs)

**Goal:** Runtime-verifiable proof that scopecam-engine loads the correct libuvc.so.

#### A) Add build ID export to uvccamera-experimental

**File:** `lib/src/main/jni/UVCCamera/uvc_build_id.c` (new file)

```c
#include <stdint.h>

#ifndef UVC_BUILD_GIT
#define UVC_BUILD_GIT "unknown"
#endif

#ifndef UVC_BUILD_TIME
#define UVC_BUILD_TIME "unknown"
#endif

__attribute__((visibility("default")))
const char* uvc_build_id(void) {
    return "uvccamera-experimental:" UVC_BUILD_GIT "@" UVC_BUILD_TIME;
}
```

#### B) Inject git/time defines in Android.mk

**File:** `lib/src/main/jni/UVCCamera/Android.mk`

Add to LOCAL_CFLAGS:

```makefile
LOCAL_CFLAGS += -DUVC_BUILD_GIT=\"$(shell git rev-parse --short HEAD)\"
LOCAL_CFLAGS += -DUVC_BUILD_TIME=\"$(shell date -u +%Y%m%dT%H%M%SZ)\"
```

#### C) Add source file to build

Add `uvc_build_id.c` to LOCAL_SRC_FILES in Android.mk.

#### D) Log build ID from scopecam-engine at camera open

**File:** `scopecam-engine/nativecode/src/main/cpp/jni/serenegiant_usb_UVCCamera.cpp`

```cpp
// Declare external
extern "C" const char* uvc_build_id(void);

// In nativeCreate or camera open path:
LOGI("libuvc build: %s", uvc_build_id());
```

**Verification:** App logcat must show git hash + timestamp matching latest build.

---

### 0-Pre.2: One-Command Sync Script

**File:** `tools/sync_to_engine.sh` (new file in uvccamera-experimental)

```bash
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Sync uvccamera-experimental → scopecam-engine prebuilts
# ============================================================

UVC_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_ROOT="${ENGINE_ROOT:-$HOME/Development/personal/scopecam-engine}"

ABIS=("arm64-v8a" "armeabi-v7a")

# Libraries to sync (basename only)
LIBS=("libuvc.so" "libusb100.so" "libjpeg-turbo1500.so")

echo "==> Building uvccamera-experimental (ndk-build)"
pushd "$UVC_REPO_ROOT/lib/src/main" >/dev/null

# Verify NDK
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to match scopecam-engine NDK (27.0.12077973)}"

# Clean + build
"$ANDROID_NDK_HOME/ndk-build" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" \
    NDK_PROJECT_PATH="$UVC_REPO_ROOT/lib/src/main" \
    NDK_APPLICATION_MK="$UVC_REPO_ROOT/lib/src/main/jni/Application.mk" \
    clean

"$ANDROID_NDK_HOME/ndk-build" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" \
    NDK_PROJECT_PATH="$UVC_REPO_ROOT/lib/src/main" \
    NDK_APPLICATION_MK="$UVC_REPO_ROOT/lib/src/main/jni/Application.mk"

popd >/dev/null

echo ""
echo "==> Copying .so files to scopecam-engine"

for abi in "${ABIS[@]}"; do
    echo "--- ABI: $abi ---"
    for lib in "${LIBS[@]}"; do
        src="$UVC_REPO_ROOT/lib/src/main/libs/$abi/$lib"
        dst="$ENGINE_ROOT/nativecode/src/main/libs/$abi/$lib"

        if [[ ! -f "$src" ]]; then
            echo "  SKIP: $lib (not built)"
            continue
        fi

        mkdir -p "$(dirname "$dst")"

        src_sha="$(shasum -a 256 "$src" | awk '{print $1}')"
        dst_sha="(none)"
        [[ -f "$dst" ]] && dst_sha="$(shasum -a 256 "$dst" | awk '{print $1}')"

        cp -f "$src" "$dst"
        new_sha="$(shasum -a 256 "$dst" | awk '{print $1}')"

        if [[ "$src_sha" == "$dst_sha" ]]; then
            echo "  $lib: unchanged"
        else
            echo "  $lib: UPDATED ($dst_sha → $new_sha)"
        fi

        # Verify copy
        if [[ "$src_sha" != "$new_sha" ]]; then
            echo "  ERROR: Copy verification failed!" >&2
            exit 1
        fi
    done
done

echo ""
echo "==> Done. Run app and verify logcat shows new build ID."
echo "    Expected pattern: uvccamera-experimental:<git>@<time>"
```

**Usage:**

```bash
cd ~/Development/personal/UVCCamera-experimental
./tools/sync_to_engine.sh
```

---

### 0-Pre.3: C++17 Standard + ABI Safety

#### A) Add C++17 flag

**File:** `lib/src/main/jni/Application.mk`

```makefile
APP_CPPFLAGS += -std=c++17
```

#### B) Add CI guard

**File:** `lib/src/main/jni/UVCCamera/UVCCamera.cpp` (top of file)

```cpp
static_assert(__cplusplus >= 201703L, "C++17 required for uvccamera-experimental");
```

#### C) ABI Boundary Rules (MANDATORY)

The boundary between libuvc.so and scopecam-engine MUST be **C ABI only**:

| Allowed | Forbidden |
|---------|-----------|
| JNI functions | Passing std::string |
| POD structs | Passing std::vector |
| Primitive types | C++ exceptions across boundary |
| Byte buffers (uint8_t*) | STL containers |
| Function pointers | C++ objects/references |

Both repos MUST use:
- Same NDK version (27.0.12077973)
- Same STL (`c++_shared`)
- Same ABI filters (arm64-v8a, armeabi-v7a)

---

## Phase 0: Immediate Wins + Verification (Week 1)

### 0.1 DECISION-009: C++17 standard flag

*Completed in Phase 0-Pre.3*

---

### 0.2 DECISION-006: PTS/SCR Plumbing

**Goal:** Expose raw PTS/SCR per completed frame without correctness claims.

#### A) Extend uvc_frame_t

**File:** `lib/src/main/jni/libuvc/include/libuvc/libuvc.h`

Add to `uvc_frame` struct (around line 455):

```c
typedef struct uvc_frame {
    void *data;
    size_t data_bytes;
    size_t actual_bytes;
    uint32_t width, height;
    enum uvc_frame_format frame_format;
    size_t step;
    uint32_t sequence;
    struct timeval capture_time;
    uvc_device_handle_t *source;
    uint8_t library_owns_data;

    // === NEW: PTS/SCR fields (Phase 0) ===
    uint32_t pts_raw;      // Raw 32-bit PTS from header
    uint32_t scr_raw;      // Raw 32-bit SCR from header
    uint8_t  ts_flags;     // Bitmask: PTS_PRESENT, SCR_PRESENT
} uvc_frame_t;

// Timestamp flags
#define UVC_TS_PTS_PRESENT   (1u << 0)
#define UVC_TS_SCR_PRESENT   (1u << 1)
#define UVC_TS_PTS_VALID     (1u << 2)  // Set after survey validates reliability
```

#### B) Wire values at frame completion

**File:** `lib/src/main/jni/libuvc/src/stream.c`

In `_uvc_swap_buffers()` or wherever frame is finalized (around line 1758):

```c
// Connect PTS/SCR to frame (Phase 0 - raw only)
frame->pts_raw = strmh->hold_pts;
frame->scr_raw = strmh->hold_last_scr;

frame->ts_flags = 0;
// Note: Check how pts_present is tracked in strmh
// May need to add tracking if not present
if (strmh->hold_pts != 0 && strmh->hold_pts != 0xFFFFFFFF) {
    frame->ts_flags |= UVC_TS_PTS_PRESENT;
}
if (strmh->hold_last_scr != 0) {
    frame->ts_flags |= UVC_TS_SCR_PRESENT;
}
```

#### C) Extend capture callback signature

**File:** `scopecam-engine/nativecode/src/main/cpp/core/UVCPreview.h`

Update typedef (line 93):

```cpp
// Extended capture callback with PTS/SCR
typedef void (*captureCallbackFunc_t)(
    void* userData,
    const uint8_t* data,
    size_t dataSize,
    int width,
    int height,
    int format,
    int64_t timestampNs,
    // === NEW: PTS/SCR fields ===
    uint32_t ptsRaw,
    uint32_t scrRaw,
    uint8_t tsFlags
);
```

#### D) Add PTS telemetry counters

**File:** `scopecam-engine/nativecode/src/main/cpp/core/StreamTelemetry.h`

Add fields:

```cpp
// PTS/SCR statistics (Phase 0)
std::atomic<uint64_t> ptsPresentFrames{0};
std::atomic<uint64_t> scrPresentFrames{0};
std::atomic<uint64_t> ptsZeroFrames{0};
std::atomic<uint64_t> ptsMaxFrames{0};  // 0xFFFFFFFF

// Last raw values (for debugging)
std::atomic<uint32_t> lastPtsRaw{0};
std::atomic<uint32_t> lastScrRaw{0};
```

---

### 0.3 TARGETED-002: PTS Reliability Survey

**Goal:** Automated survey to determine if PTS is trustworthy.

#### Implementation

Add feature flag to StreamTelemetry:

```cpp
bool ptsSurveyEnabled = false;
static constexpr int PTS_SURVEY_INTERVAL = 30;  // Log every Nth frame

void recordPtsSample(uint32_t ptsRaw, uint32_t scrRaw, uint8_t tsFlags,
                     int64_t hostNs, int width, int height, int format) {
    if (!ptsSurveyEnabled) return;
    if (framesReceived.load() % PTS_SURVEY_INTERVAL != 0) return;

    // Log compact JSON for analysis
    LOGI("PTS_SURVEY: {\"frame\":%lu,\"pts\":%u,\"scr\":%u,\"flags\":%d,"
         "\"host_ns\":%lld,\"res\":\"%dx%d\",\"fmt\":%d}",
         framesReceived.load(), ptsRaw, scrRaw, tsFlags,
         hostNs, width, height, format);
}
```

**Analysis Criteria:**
- PTS present on ≥95% of frames
- Not constant 0 or 0xFFFFFFFF
- Monotonic within wrap windows

**Output:** Enable `UVC_TS_PTS_VALID` flag after survey passes.

---

### 0.4 DECISION-007: Thread Priority

**Goal:** Raise USB thread priority with Android-supported mechanisms.

#### A) Native thread priority (uvccamera-experimental)

**File:** `lib/src/main/jni/libuvc/src/stream.c` (thread start)

```c
#include <sys/resource.h>

// At start of USB processing thread:
pthread_setname_np(pthread_self(), "uvc-usb");

errno = 0;
int rc = setpriority(PRIO_PROCESS, 0, -10);
int actual = getpriority(PRIO_PROCESS, 0);
LOGI("USB thread priority: requested=-10, rc=%d, errno=%d, actual=%d",
     rc, errno, actual);

// TODO: Record in telemetry when JNI bridge available
```

#### B) Kotlin-side priority (scopecam-engine)

**File:** `scopecam-engine/camera-platform/.../SafeUvcCameraManager.kt`

```kotlin
private fun setThreadPriority() {
    try {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        Log.d(TAG, "Thread priority set to URGENT_AUDIO")
    } catch (e: Exception) {
        Log.w(TAG, "Failed to set thread priority: ${e.message}")
    }
}
```

#### C) Telemetry additions

**File:** `scopecam-engine/nativecode/src/main/cpp/core/StreamTelemetry.h`

```cpp
// Thread priority telemetry
int8_t requestedNice{-10};
std::atomic<int8_t> effectiveNice{0};
std::atomic<bool> niceSetSucceeded{false};
std::atomic<bool> javaPriorityApplied{false};
```

---

### 0.5 TARGETED-004: API 34+ USB Verification

**Test Plan (not code):**

1. Device inventory with telemetry auto-capture:
   ```kotlin
   fun logDeviceInfo() {
       Log.i(TAG, "Device: ${Build.MANUFACTURER} ${Build.MODEL}")
       Log.i(TAG, "API Level: ${Build.VERSION.SDK_INT}")
       Log.i(TAG, "Android: ${Build.VERSION.RELEASE}")
   }
   ```

2. Test matrix:
   - Enumerate, request permission, open device
   - Verify FD injection works
   - 20x connect/disconnect stress test
   - Screen off/on during stream
   - Doze mode behavior

3. **Deliverable:** `docs/testing/API34-verification-results.md`

---

## Phase 1: UVC Compliance (Weeks 2-3)

### 1.1 DECISION-011: GET_INFO Implementation

**Goal:** Query control capabilities per UVC spec with verification.

#### A) Add uvc_get_info() function

**File:** `lib/src/main/jni/libuvc/src/ctrl.c`

```c
uvc_error_t uvc_get_info(
    uvc_device_handle_t *devh,
    uint8_t unit_id,
    uint8_t control_selector,
    uint8_t *info_out
) {
    uint8_t info = 0;

    // Log setup packet for verification (debug mode)
    #ifdef DEBUG
    uint16_t wValue = (control_selector << 8);
    uint16_t wIndex = (unit_id << 8) | devh->info->ctrl_if.bInterfaceNumber;
    LOGD("GET_INFO: unit=%d, sel=%d, wValue=0x%04x, wIndex=0x%04x",
         unit_id, control_selector, wValue, wIndex);
    #endif

    uvc_error_t err = uvc_query_ctrl(
        devh,
        UVC_GET_INFO,
        unit_id,
        devh->info->ctrl_if.bInterfaceNumber,
        control_selector,
        &info,
        1
    );

    if (err == UVC_SUCCESS) {
        *info_out = info;
    }

    return err;
}
```

#### B) Info byte interpretation

```c
// UVC 1.5 §4.2.1.2 GET_INFO response bits
#define UVC_CTRL_CAP_GET           (1 << 0)
#define UVC_CTRL_CAP_SET           (1 << 1)
#define UVC_CTRL_CAP_DISABLED      (1 << 2)
#define UVC_CTRL_CAP_AUTO_UPDATE   (1 << 3)
#define UVC_CTRL_CAP_ASYNC         (1 << 4)

typedef struct {
    uint8_t supports_get : 1;
    uint8_t supports_set : 1;
    uint8_t disabled : 1;
    uint8_t auto_update : 1;
    uint8_t async_capable : 1;
    uint8_t reserved : 3;
} uvc_ctrl_caps_t;

static inline uvc_ctrl_caps_t uvc_parse_ctrl_caps(uint8_t info) {
    return (uvc_ctrl_caps_t){
        .supports_get = (info & UVC_CTRL_CAP_GET) != 0,
        .supports_set = (info & UVC_CTRL_CAP_SET) != 0,
        .disabled = (info & UVC_CTRL_CAP_DISABLED) != 0,
        .auto_update = (info & UVC_CTRL_CAP_AUTO_UPDATE) != 0,
        .async_capable = (info & UVC_CTRL_CAP_ASYNC) != 0,
    };
}
```

#### C) Fallback behavior

```c
// If GET_INFO fails (timeout, stall, garbage):
// 1. Mark capabilities as unknown
// 2. Infer from GET_CUR / SET_CUR success
// 3. Cache empirical results

typedef enum {
    CTRL_CAP_SOURCE_UNKNOWN = 0,
    CTRL_CAP_SOURCE_GET_INFO = 1,
    CTRL_CAP_SOURCE_EMPIRICAL = 2,
} ctrl_cap_source_t;
```

#### D) Verification requirement

**Before shipping:** Compare GET_INFO results against Linux uvcvideo on same camera for:
- Exposure (CT, selector 4)
- Brightness (PU, selector 2)
- Gain (PU, selector 4)

Document in `docs/testing/GET_INFO-verification.md`.

---

## Phase 2: Reliability (Weeks 4-5)

### 2.1 DECISION-014: Recovery State Machine

**Goal:** Convert detection-only to systematic recovery with quality ladder.

#### A) Enhance existing RecoveryStrategy

**File:** `scopecam-engine/camera-platform/.../RecoveryStrategy.kt`

The existing 4-level strategy (PREVIEW_ONLY → CAMERA → INTERFACE → FULL) provides the escalation. Add:

```kotlin
// Quality ladder for graceful degradation
data class QualityStep(
    val width: Int,
    val height: Int,
    val fps: Int,
    val format: CaptureFormat
)

class QualityLadder(private val steps: List<QualityStep>) {
    private var currentIndex = 0

    fun stepDown(): QualityStep? {
        if (currentIndex < steps.lastIndex) {
            currentIndex++
            return steps[currentIndex]
        }
        return null  // Already at lowest
    }

    fun stepUp(): QualityStep? {
        if (currentIndex > 0) {
            currentIndex--
            return steps[currentIndex]
        }
        return null  // Already at highest
    }

    fun current(): QualityStep = steps[currentIndex]
    fun reset() { currentIndex = 0 }
}
```

#### B) Quality ladder source

Populate from camera's enumerated modes + vendor overrides:

```kotlin
fun buildQualityLadder(camera: UvcCamera): QualityLadder {
    val modes = camera.supportedModes
        .sortedByDescending { it.width * it.height * it.fps }

    return QualityLadder(modes.map {
        QualityStep(it.width, it.height, it.fps, it.format)
    })
}
```

#### C) Observable transitions

```kotlin
data class StateTransition(
    val from: StreamState,
    val to: StreamState,
    val trigger: RecoveryEvent,
    val action: RecoveryAction,
    val timestampMs: Long
)

// Log every transition
fun onTransition(transition: StateTransition) {
    Log.i(TAG, "State: ${transition.from} → ${transition.to} " +
          "trigger=${transition.trigger} action=${transition.action}")
    telemetry.recordTransition(transition)
}
```

---

### 2.2 DECISION-013: Clock Synchronization

**Goal:** PTS→host time with confidence metric.

**Location:** scopecam-engine/nativecode/ (C++20)

```cpp
class ClockSynchronizer {
public:
    struct SyncResult {
        int64_t hostTimeNs;
        float confidence;     // 0.0 - 1.0
        float driftPpm;
        TimestampSource source;
    };

    void addSample(uint32_t ptsRaw, int64_t hostNs) {
        uint64_t unwrapped = unwrapPts(ptsRaw);

        samples_.push_back({unwrapped, hostNs});
        if (samples_.size() > kWindowSize) {
            samples_.pop_front();
        }

        if (samples_.size() >= kMinSamples) {
            computeRegression();
        }
    }

    SyncResult ptsToHostTime(uint32_t ptsRaw) const {
        if (samples_.size() < kMinSamples) {
            // Bootstrap period - use host time only
            return {0, 0.0f, 0.0f, TimestampSource::HOST_MONOTONIC};
        }

        uint64_t unwrapped = unwrapPts(ptsRaw);
        int64_t estimated = static_cast<int64_t>(slope_ * unwrapped + intercept_);
        return {estimated, confidence_, driftPpm_, TimestampSource::DEVICE_PTS};
    }

private:
    static constexpr size_t kWindowSize = 100;
    static constexpr size_t kMinSamples = 10;

    uint64_t unwrapPts(uint32_t pts) const {
        if (pts < lastRawPts_ && (lastRawPts_ - pts) > 0x80000000) {
            wrapCount_++;
        }
        lastRawPts_ = pts;
        return (static_cast<uint64_t>(wrapCount_) << 32) | pts;
    }

    void computeRegression() {
        // Least squares: hostNs = slope * pts + intercept
        // slope ≈ 1e9 / clock_frequency_hz (typically 15MHz → ~66.67)
        // ... standard least squares implementation
    }

    std::deque<std::pair<uint64_t, int64_t>> samples_;
    mutable uint32_t lastRawPts_ = 0;
    mutable uint32_t wrapCount_ = 0;
    double slope_ = 0.0;
    double intercept_ = 0.0;
    float confidence_ = 0.0f;
    float driftPpm_ = 0.0f;
};
```

---

## Phase 3: H.264/HEVC Pipeline (Weeks 6-9)

### 3.0 TARGETED-003: NAL Delivery Format Investigation

**Goal:** Determine how H.264 camera delivers NAL units.

1. Capture raw UVC payloads (first 1000 frames)
2. Identify:
   - Annex B start codes (0x00000001) vs length-prefixed
   - Fragmentation across payloads
   - SPS/PPS delivery pattern
3. Document in `docs/h264/NAL-format-analysis.md`

---

### 3.1 DECISION-012: MediaCodec Integration

**Ownership Model (BINDING):**

| Component | Owner | Rationale |
|-----------|-------|-----------|
| Output Surface | **Kotlin** | Lifecycle-friendly, survives rotation |
| MediaCodec instance | **Kotlin** | Android API, configuration |
| NAL assembly | **Native (C++)** | Performance, reuse |
| Access Unit queue | **Native → Kotlin** | JNI callback |

#### Architecture

```
USB H.264 Payload → NAL Assembly (native) → AU Callback → MediaCodec (Kotlin) → Surface
                                                              ↓
                                                    Optional CPU buffer for analysis
```

#### A) NAL Assembly (scopecam-engine native)

```cpp
class NalAssembler {
public:
    struct AccessUnit {
        std::vector<uint8_t> data;
        int64_t timestampNs;
        bool isKeyframe;  // IDR
    };

    using AuCallback = std::function<void(AccessUnit&&)>;

    void setCallback(AuCallback cb) { callback_ = std::move(cb); }

    void processPayload(const uint8_t* data, size_t size, int64_t timestampNs) {
        // Detect NAL boundaries
        // Reassemble fragments
        // Emit complete AUs via callback
    }

    void onPacketLoss() {
        // Wait for next IDR before resuming
        waitingForIdr_ = true;
    }

private:
    AuCallback callback_;
    std::vector<uint8_t> pending_;
    bool waitingForIdr_ = true;  // Start by waiting for keyframe
};
```

#### B) Kotlin MediaCodec lifecycle

```kotlin
class H264Decoder(private val surface: Surface) {
    private var codec: MediaCodec? = null

    fun configure(width: Int, height: Int, sps: ByteArray, pps: ByteArray) {
        val format = MediaFormat.createVideoFormat("video/avc", width, height).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(sps))
            setByteBuffer("csd-1", ByteBuffer.wrap(pps))
        }

        codec = MediaCodec.createDecoderByType("video/avc").apply {
            configure(format, surface, null, 0)
            start()
        }
    }

    fun queueAccessUnit(data: ByteArray, timestampUs: Long, isKeyframe: Boolean) {
        val index = codec?.dequeueInputBuffer(0) ?: return
        if (index < 0) return

        codec?.getInputBuffer(index)?.apply {
            clear()
            put(data)
        }

        val flags = if (isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        codec?.queueInputBuffer(index, 0, data.size, timestampUs, flags)
    }

    fun release() {
        codec?.stop()
        codec?.release()
        codec = null
    }
}
```

---

## Phase 4: XU Framework + Polish (Weeks 10-12)

### 4.1 DECISION-015: Extension Unit Framework

**Location:** scopecam-engine/nativecode/ (C++20)

#### Expected type decision

Use `tl::expected` (header-only, battle-tested):

```cpp
#include <tl/expected.hpp>

template<typename T>
using XuResult = tl::expected<T, UvcError>;
```

Or minimal local implementation:

```cpp
template<typename T, typename E>
class Expected {
    std::variant<T, E> storage_;
public:
    bool has_value() const { return storage_.index() == 0; }
    T& value() { return std::get<0>(storage_); }
    const T& value() const { return std::get<0>(storage_); }
    E& error() { return std::get<1>(storage_); }
    const E& error() const { return std::get<1>(storage_); }

    static Expected success(T val) { Expected e; e.storage_ = std::move(val); return e; }
    static Expected failure(E err) { Expected e; e.storage_ = std::move(err); return e; }
};
```

#### Raw transport (calls into libuvc via JNI)

```cpp
class XuTransport {
public:
    XuResult<std::vector<uint8_t>> get(uint8_t unitId, uint8_t selector, size_t len);
    XuResult<void> set(uint8_t unitId, uint8_t selector, const uint8_t* data, size_t len);
    XuResult<uvc_ctrl_caps_t> getInfo(uint8_t unitId, uint8_t selector);
};
```

#### Typed wrappers (example: thermal sensor)

```cpp
class ThermalXuControl {
    XuTransport& transport_;
    uint8_t unitId_;
    uint8_t selector_;

public:
    ThermalXuControl(XuTransport& t, uint8_t unit, uint8_t sel)
        : transport_(t), unitId_(unit), selector_(sel) {}

    // Returns temperature in deci-Celsius (e.g., 375 = 37.5°C)
    XuResult<int16_t> readTemperature() {
        auto result = transport_.get(unitId_, selector_, 2);
        if (!result.has_value()) return XuResult<int16_t>::failure(result.error());

        // Little-endian 16-bit signed
        int16_t temp = static_cast<int16_t>(result.value()[0] | (result.value()[1] << 8));
        return XuResult<int16_t>::success(temp);
    }
};
```

---

## Cross-Cutting: Observable Everything

### Telemetry aggregation (already implemented in scopecam-engine)

The existing 37-field StreamTelemetry + TelemetryCollector provides the infrastructure.

**Additions for this implementation:**

| Field | Type | Phase |
|-------|------|-------|
| `buildId` | string | 0-Pre |
| `ptsRaw`, `scrRaw`, `tsFlags` | uint32/uint8 | 0 |
| `ptsPresentFrames`, `scrPresentFrames` | counter | 0 |
| `effectiveNice`, `javaPriorityApplied` | int8/bool | 0 |
| `getInfoAttempts`, `getInfoTimeouts` | counter | 1 |
| `clockSyncConfidence`, `clockSyncDriftPpm` | float | 2 |
| `auQueueDepth`, `nalAssemblyErrors` | counter | 3 |
| `xuQuirkHits` | counter | 4 |

### Device identity (auto-captured)

```kotlin
fun logDeviceIdentity() {
    telemetry.setString("device.manufacturer", Build.MANUFACTURER)
    telemetry.setString("device.model", Build.MODEL)
    telemetry.setInt("device.apiLevel", Build.VERSION.SDK_INT)
    telemetry.setString("device.android", Build.VERSION.RELEASE)
}
```

---

## Implementation Checklist

### Phase 0-Pre (Must complete first)

- [ ] Create `uvc_build_id.c` with git/time defines
- [ ] Add to Android.mk build
- [ ] Log build ID from scopecam-engine
- [ ] Create `tools/sync_to_engine.sh`
- [ ] Verify sync workflow works end-to-end
- [ ] Add `APP_CPPFLAGS += -std=c++17`
- [ ] Add static_assert for C++17

### Phase 0 (Week 1)

- [ ] Add PTS/SCR fields to uvc_frame_t
- [ ] Wire values in stream.c
- [ ] Extend captureCallbackFunc_t signature
- [ ] Add PTS telemetry counters
- [ ] Implement PTS survey mode
- [ ] Add thread priority (native + Kotlin)
- [ ] Run API 34+ verification tests

### Phase 1 (Weeks 2-3)

- [ ] Implement uvc_get_info()
- [ ] Add verification logging
- [ ] Implement fallback behavior
- [ ] Compare against Linux uvcvideo
- [ ] Add control capability caching

### Phase 2 (Weeks 4-5)

- [ ] Enhance RecoveryStrategy with quality ladder
- [ ] Implement observable transitions
- [ ] Implement ClockSynchronizer
- [ ] Add confidence metric
- [ ] Add RMSE telemetry

### Phase 3 (Weeks 6-9)

- [ ] Capture NAL format from H.264 camera
- [ ] Document delivery format
- [ ] Implement NalAssembler
- [ ] Implement H264Decoder (Kotlin)
- [ ] Integrate with recovery FSM
- [ ] Add AU queue telemetry

### Phase 4 (Weeks 10-12)

- [ ] Choose Expected type (tl::expected vs local)
- [ ] Implement XuTransport
- [ ] Implement typed XU wrappers
- [ ] Integrate quirk registry
- [ ] Add XU telemetry

---

*End of Implementation Plan*
