# INVESTIGATION-001: Essential Questions for Architectural Framework

**Status:** Investigation Required
**Created:** 2026-01-12
**Author:** Jeffrey Litecky / Claude
**Project:** ScopeCam - UVCCamera Library Modernization
**Purpose:** Evidence-based validation of 2026 Architecture Plan

---

## Executive Summary

Before finalizing the architectural framework, we must answer **47 essential questions** through direct codebase investigation. These questions map to specific architectural decisions in the 2026 plan and will determine:

1. What already exists (avoid reinventing)
2. What constraints we face (libuvc, Android APIs, hardware)
3. What is genuinely feasible vs. aspirational
4. Where the real complexity lives

**Investigation Principle:** Every answer must include:
- File path(s) and line number(s)
- Code excerpt or summary
- Implication for the architectural plan

---

## Investigation Categories

| Category | Questions | Architectural Impact |
|----------|-----------|---------------------|
| A. Transport Layer | 8 | Bulk vs. isochronous strategy |
| B. libuvc Integration | 10 | Fork vs. wrapper vs. rewrite decision |
| C. Payload Pipeline | 7 | Format support, decode paths |
| D. Timestamp System | 6 | PTS/SCR feasibility |
| E. Control Plane | 5 | GET_INFO, XU framework |
| F. Memory & Threading | 6 | Zero-copy feasibility |
| G. Build System | 5 | CMake migration scope |
| **Total** | **47** | |

---

## Category A: Transport Layer Reality

These questions determine our USB transport strategy and whether isochronous is even possible.

### A-01: What USB transfer types are currently used?

**Why It Matters:**
The 2026 plan assumes "bulk-first with isochronous as premium path." We need to know the current state.

**Investigation:**
```bash
grep -rn 'LIBUSB_TRANSFER_TYPE_\|libusb_alloc_transfer\|libusb_submit_transfer' $JNI_PATH
grep -rn 'bulk\|isoc\|isochronous\|interrupt' $JNI_PATH --include="*.cpp" --include="*.h"
```

**Expected Evidence:**
- Transfer type constants used
- Transfer allocation patterns
- Any isochronous-specific code

**Architectural Decision Unlocked:**
→ Do we need to add isochronous, or is it already there?

---

### A-02: How is USB device access obtained?

**Why It Matters:**
The plan requires FD injection from Kotlin. We need to verify current access pattern.

**Investigation:**
```bash
grep -rn 'libusb_open\|libusb_wrap_sys_device\|libusb_open_device_with_vid_pid' $JNI_PATH
grep -rn 'getFileDescriptor\|UsbDeviceConnection' $KOTLIN_PATH
```

**Expected Evidence:**
- Direct device open vs. FD wrapping
- How FD flows from Kotlin to native

**Architectural Decision Unlocked:**
→ Is FD injection already implemented? (OPP-011 status)

---

### A-03: What alternate setting selection logic exists?

**Why It Matters:**
UVC bandwidth negotiation requires alt setting selection. This is critical for isochronous.

**Investigation:**
```bash
grep -rn 'libusb_set_interface_alt_setting\|bAlternateSetting\|altsetting' $JNI_PATH
```

**Expected Evidence:**
- Alt setting selection code
- Bandwidth calculation logic
- Default vs. negotiated settings

**Architectural Decision Unlocked:**
→ How sophisticated is current bandwidth negotiation?

---

### A-04: How are USB errors handled and recovered?

**Why It Matters:**
The plan specifies a "recovery state machine." What exists today?

**Investigation:**
```bash
grep -rn 'LIBUSB_ERROR\|libusb_strerror\|USB.*error\|transfer.*failed' $JNI_PATH
grep -rn 'reconnect\|recovery\|retry' $JNI_PATH
```

**Expected Evidence:**
- Error code handling
- Retry logic
- Recovery state machine (if any)

**Architectural Decision Unlocked:**
→ Build on existing recovery, or design from scratch?

---

### A-05: What USB permissions model is used?

**Why It Matters:**
Android 16 has stricter USB permissions. We need to verify compliance.

**Investigation:**
```bash
grep -rn 'USB_PERMISSION\|UsbManager\|requestPermission' $KOTLIN_PATH
grep -rn 'ACTION_USB' $PROJECT_ROOT --include="*.xml" --include="*.kt"
```

**Expected Evidence:**
- Permission request flow
- Intent filter declarations
- Runtime permission handling

**Architectural Decision Unlocked:**
→ Android 16 USB permission compliance status

---

### A-06: Is there any isochronous-specific infrastructure?

**Why It Matters:**
The plan treats isochronous as "premium path." Does any infrastructure exist?

**Investigation:**
```bash
grep -rn 'isoc\|ISO_PACKETS\|num_iso_packets\|iso_packet_desc' $JNI_PATH
grep -rn 'URB_ISO\|USBDEVFS_SUBMITURB' $JNI_PATH
```

**Expected Evidence:**
- Isochronous packet handling
- ISO-specific buffer management
- Any conditional isochronous code paths

**Architectural Decision Unlocked:**
→ Isochronous: build from scratch or enhance existing?

---

### A-07: What is the USB read thread architecture?

**Why It Matters:**
The plan requires "USB read thread(s) with prioritized consistent cadence."

**Investigation:**
```bash
grep -rn 'capture.*thread\|usb.*thread\|read.*thread' $JNI_PATH
grep -rn 'pthread_create\|std::thread\|std::jthread' $JNI_PATH
```

**Expected Evidence:**
- Thread creation points
- Thread priority settings
- Thread naming/identification

**Architectural Decision Unlocked:**
→ Thread architecture: refactor or enhance?

---

### A-08: How is USB disconnection detected and handled?

**Why It Matters:**
"Hot-plug and disconnect correctness is a headline feature" per the plan.

**Investigation:**
```bash
grep -rn 'disconnect\|detach\|LIBUSB_TRANSFER_NO_DEVICE\|device.*removed' $JNI_PATH
grep -rn 'ACTION_USB_DEVICE_DETACHED' $KOTLIN_PATH
```

**Expected Evidence:**
- Disconnect detection mechanism
- Cleanup on disconnect
- Thread/resource cleanup

**Architectural Decision Unlocked:**
→ Disconnect handling: complete or needs work?

---

## Category B: libuvc Integration Depth

These questions determine whether we fork, wrap, or replace libuvc.

### B-01: What version/fork of libuvc is in use?

**Why It Matters:**
Understanding our libuvc baseline is foundational.

**Investigation:**
```bash
find $PROJECT_ROOT -name "libuvc*" -type d
find $PROJECT_ROOT -name "*.h" -path "*libuvc*" -exec head -20 {} \;
grep -rn 'LIBUVC_VERSION\|libuvc_version' $JNI_PATH
```

**Expected Evidence:**
- libuvc source location
- Version information
- Fork provenance (if known)

**Architectural Decision Unlocked:**
→ Baseline for evaluating upstream changes

---

### B-02: What libuvc APIs are actually used?

**Why It Matters:**
We need to know our API surface to evaluate wrapper vs. fork strategies.

**Investigation:**
```bash
grep -rn '^#include.*libuvc\|#include.*uvc\.h' $JNI_PATH
grep -rn 'uvc_[a-z_]*(' $JNI_PATH | sed 's/.*\(uvc_[a-z_]*\)(.*/\1/' | sort -u
```

**Expected Evidence:**
- Complete list of libuvc functions called
- Header dependencies
- Wrapper functions vs. direct calls

**Architectural Decision Unlocked:**
→ API surface for abstraction layer design

---

### B-03: Have any libuvc modifications been made?

**Why It Matters:**
If we've already modified libuvc, we're already maintaining a fork.

**Investigation:**
```bash
# If git history available
git log --oneline -- '**/libuvc/**' 2>/dev/null | head -20

# Look for local patches or modifications
find $PROJECT_ROOT -path "*libuvc*" -name "*.patch"
grep -rn 'MODIFIED\|PATCHED\|SCOPECAM\|LOCAL' $JNI_PATH --include="*.h" --include="*.cpp"
```

**Expected Evidence:**
- Modification history
- Patch files
- Local customizations

**Architectural Decision Unlocked:**
→ Are we already a fork? What's the maintenance burden?

---

### B-04: How does libuvc handle streaming?

**Why It Matters:**
The plan requires understanding streaming internals for PTS/SCR extraction.

**Investigation:**
```bash
grep -rn 'uvc_stream_\|uvc_start_streaming\|uvc_stop_streaming' $JNI_PATH
grep -rn 'callback\|frame_callback\|stream_callback' $JNI_PATH
```

**Expected Evidence:**
- Streaming initialization
- Callback registration
- Frame delivery mechanism

**Architectural Decision Unlocked:**
→ Where to inject timestamp extraction

---

### B-05: How does libuvc parse UVC descriptors?

**Why It Matters:**
UVC 1.5 compliance requires descriptor parsing understanding.

**Investigation:**
```bash
grep -rn 'uvc_parse\|descriptor\|VS_FORMAT\|VS_FRAME' $JNI_PATH
grep -rn 'bFormatIndex\|bFrameIndex\|dwFrameInterval' $JNI_PATH
```

**Expected Evidence:**
- Descriptor parsing code
- Format/frame enumeration
- Interval handling

**Architectural Decision Unlocked:**
→ UVC 1.5 descriptor support gap

---

### B-06: What is the frame assembly logic?

**Why It Matters:**
"Frame boundary correctness even under loss/jitter" is critical.

**Investigation:**
```bash
grep -rn 'FID\|EOF\|ERR\|PTS\|SCR\|payload.*header' $JNI_PATH
grep -rn 'frame.*complete\|frame.*boundary\|assemble' $JNI_PATH
```

**Expected Evidence:**
- Header bit parsing
- Frame completion detection
- Error bit handling

**Architectural Decision Unlocked:**
→ Frame assembly robustness level

---

### B-07: Is there any UVC 1.5 specific code?

**Why It Matters:**
The plan targets UVC 1.5. What's already there?

**Investigation:**
```bash
grep -rn 'UVC.*1\.5\|H\.264\|H\.265\|HEVC\|frame.based' $JNI_PATH
grep -rn 'VS_FORMAT_H264\|VS_FORMAT_VP8\|FRAME_BASED' $JNI_PATH
```

**Expected Evidence:**
- UVC 1.5 format constants
- Frame-based payload handling
- Encoding format support

**Architectural Decision Unlocked:**
→ H.264/HEVC: build from scratch or enhance?

---

### B-08: How are UVC controls implemented?

**Why It Matters:**
"Control plane perfection" requires understanding current implementation.

**Investigation:**
```bash
grep -rn 'uvc_get_\|uvc_set_\|GET_CUR\|SET_CUR\|GET_INFO' $JNI_PATH
grep -rn 'CT_\|PU_\|control.*selector' $JNI_PATH
```

**Expected Evidence:**
- Control get/set implementation
- Selector handling
- GET_INFO usage (if any)

**Architectural Decision Unlocked:**
→ Control plane: registry from scratch or refactor?

---

### B-09: Is Extension Unit support present?

**Why It Matters:**
XU framework is a major feature in the plan.

**Investigation:**
```bash
grep -rn 'XU\|extension.*unit\|GUID\|vendor.*control' $JNI_PATH
grep -rn 'EU_\|bUnitID' $JNI_PATH
```

**Expected Evidence:**
- XU enumeration code
- XU control code
- Vendor-specific implementations

**Architectural Decision Unlocked:**
→ XU: build from scratch or extend?

---

### B-10: What error handling exists in libuvc layer?

**Why It Matters:**
The plan requires "structured error taxonomy."

**Investigation:**
```bash
grep -rn 'UVC_ERROR\|uvc_strerror\|uvc_perror' $JNI_PATH
grep -rn 'enum.*error\|error.*code' $JNI_PATH --include="*.h"
```

**Expected Evidence:**
- Error enumeration
- Error propagation patterns
- Error context preservation

**Architectural Decision Unlocked:**
→ Error taxonomy: design from scratch or extend?

---

## Category C: Payload Pipeline

These questions determine our format support and decode path strategy.

### C-01: What payload formats are currently supported?

**Why It Matters:**
The plan specifies "H.264 first, MJPEG second, YUYV third."

**Investigation:**
```bash
grep -rn 'MJPEG\|YUYV\|NV12\|H264\|H265\|FORMAT_' $JNI_PATH
grep -rn 'VS_FORMAT_\|format.*index\|fourcc' $JNI_PATH
```

**Expected Evidence:**
- Format constants
- Format negotiation code
- Decode paths per format

**Architectural Decision Unlocked:**
→ Format support matrix baseline

---

### C-02: How is MJPEG decoded?

**Why It Matters:**
MJPEG decode path determines CPU vs. hardware strategy.

**Investigation:**
```bash
grep -rn 'jpeg\|turbo\|tjDecompress\|JPEG' $JNI_PATH
find $PROJECT_ROOT -name "*jpeg*" -o -name "*turbo*"
```

**Expected Evidence:**
- JPEG library used
- Decode destination (CPU buffer? GPU buffer?)
- Color conversion path

**Architectural Decision Unlocked:**
→ MJPEG: optimize existing or replace?

---

### C-03: Is MediaCodec used for any decoding?

**Why It Matters:**
"Pixel-zero-touch" for H.264 requires MediaCodec.

**Investigation:**
```bash
grep -rn 'MediaCodec\|AMediaCodec\|codec' $JNI_PATH $KOTLIN_PATH
grep -rn 'createDecoderByType\|configure.*Surface' $KOTLIN_PATH
```

**Expected Evidence:**
- MediaCodec usage
- Surface configuration
- Async vs. sync mode

**Architectural Decision Unlocked:**
→ H.264 path: build from scratch or integrate?

---

### C-04: How are decoded frames delivered?

**Why It Matters:**
Understanding current delivery determines refactoring scope.

**Investigation:**
```bash
grep -rn 'callback.*frame\|onFrame\|frame.*received' $JNI_PATH $KOTLIN_PATH
grep -rn 'ByteBuffer\|ByteArray\|AHardwareBuffer' $JNI_PATH
```

**Expected Evidence:**
- Frame callback mechanism
- Buffer types used
- Copy count in path

**Architectural Decision Unlocked:**
→ Frame delivery: refactor or redesign?

---

### C-05: What colorspace conversions exist?

**Why It Matters:**
The plan requires "GPU conversion where feasible, else SIMD CPU."

**Investigation:**
```bash
grep -rn 'YUV\|RGB\|NV12\|convert\|colorspace' $JNI_PATH
grep -rn 'SIMD\|NEON\|intrinsic' $JNI_PATH
```

**Expected Evidence:**
- Conversion functions
- SIMD optimizations
- GPU shader usage

**Architectural Decision Unlocked:**
→ Conversion: optimize or replace?

---

### C-06: Is there any GPU rendering pipeline?

**Why It Matters:**
"GPU-visible targets" require existing GPU infrastructure.

**Investigation:**
```bash
grep -rn 'EGL\|OpenGL\|GLES\|Texture\|Shader' $JNI_PATH
grep -rn 'ANativeWindow\|Surface.*native' $JNI_PATH
```

**Expected Evidence:**
- EGL/OpenGL usage
- Texture upload paths
- Shader programs

**Architectural Decision Unlocked:**
→ GPU pipeline: enhance or build?

---

### C-07: What is the buffer management architecture?

**Why It Matters:**
The plan requires "triple buffer" and "bounded queues."

**Investigation:**
```bash
grep -rn 'buffer.*pool\|ring.*buffer\|queue' $JNI_PATH
grep -rn 'acquire.*buffer\|release.*buffer' $JNI_PATH
```

**Expected Evidence:**
- Buffer pool implementation
- Queue structures
- Backpressure handling

**Architectural Decision Unlocked:**
→ Buffer management: refactor or replace?

---

## Category D: Timestamp System

These questions determine PTS/SCR extraction feasibility.

### D-01: Are UVC payload headers currently parsed?

**Why It Matters:**
PTS/SCR are in payload headers. If we're discarding them, we need modification.

**Investigation:**
```bash
grep -rn 'payload.*header\|header.*length\|BFH\|HLE' $JNI_PATH
grep -rn 'PTS\|SCR\|SOF\|presentation.*time' $JNI_PATH
```

**Expected Evidence:**
- Header parsing code
- PTS/SCR field extraction
- What's kept vs. discarded

**Architectural Decision Unlocked:**
→ OPP-008: Is PTS/SCR already there?

---

### D-02: What timestamp is currently used for frames?

**Why It Matters:**
The plan specifies "timestamp ladder" with multiple sources.

**Investigation:**
```bash
grep -rn 'timestamp\|time.*stamp\|pts\|dts' $JNI_PATH
grep -rn 'CLOCK_MONOTONIC\|System.nanoTime\|currentTimeMillis' $JNI_PATH $KOTLIN_PATH
```

**Expected Evidence:**
- Timestamp source
- Timestamp assignment point
- Timestamp propagation

**Architectural Decision Unlocked:**
→ Timestamp: enhance or redesign?

---

### D-03: Is there any clock synchronization logic?

**Why It Matters:**
The plan requires "regression/Kalman model" for clock sync.

**Investigation:**
```bash
grep -rn 'sync\|drift\|regression\|kalman\|clock' $JNI_PATH
grep -rn 'wrap\|overflow\|32.bit' $JNI_PATH
```

**Expected Evidence:**
- Clock sync implementation (if any)
- Wrap handling
- Drift correction

**Architectural Decision Unlocked:**
→ Clock sync: build from scratch or enhance?

---

### D-04: How are timestamps exposed to Kotlin?

**Why It Matters:**
The plan requires timestamp accessibility at API layer.

**Investigation:**
```bash
grep -rn 'timestamp\|pts\|presentationTime' $KOTLIN_PATH
grep -rn 'FrameInfo\|Timestamp\|TimingInfo' $KOTLIN_PATH
```

**Expected Evidence:**
- Timestamp data structures
- API exposure
- Precision level

**Architectural Decision Unlocked:**
→ Timestamp API: design from scratch or extend?

---

### D-05: Is releaseOutputBufferAtTime used?

**Why It Matters:**
This is how timestamps become real in compositor pipeline.

**Investigation:**
```bash
grep -rn 'releaseOutputBufferAtTime\|renderOutput.*time' $JNI_PATH $KOTLIN_PATH
grep -rn 'AMediaCodec_releaseOutputBufferAtTime' $JNI_PATH
```

**Expected Evidence:**
- Timed release usage
- Surface timing integration

**Architectural Decision Unlocked:**
→ Surface timing: already implemented?

---

### D-06: What timestamp-related telemetry exists?

**Why It Matters:**
The plan requires "syncConfidence and drift in telemetry."

**Investigation:**
```bash
grep -rn 'jitter\|latency\|delay\|variance' $JNI_PATH
grep -rn 'stat.*time\|timing.*metric' $JNI_PATH
```

**Expected Evidence:**
- Timing metrics
- Jitter measurement
- Latency tracking

**Architectural Decision Unlocked:**
→ Timestamp telemetry: build from scratch or enhance?

---

## Category E: Control Plane

These questions determine control system architecture.

### E-01: Is GET_INFO used for capability discovery?

**Why It Matters:**
The plan requires "GET_INFO caching with invalidation rules."

**Investigation:**
```bash
grep -rn 'GET_INFO\|info_bitmap\|capabilities' $JNI_PATH
grep -rn 'UVC_GET_INFO' $JNI_PATH
```

**Expected Evidence:**
- GET_INFO implementation
- Capability caching
- Per-control metadata

**Architectural Decision Unlocked:**
→ GET_INFO: implement or enhance?

---

### E-02: Are control ranges queried (MIN/MAX/DEF/RES)?

**Why It Matters:**
The plan requires "every range is enforced client-side."

**Investigation:**
```bash
grep -rn 'GET_MIN\|GET_MAX\|GET_DEF\|GET_RES' $JNI_PATH
grep -rn 'min.*value\|max.*value\|default.*value' $JNI_PATH
```

**Expected Evidence:**
- Range query implementation
- Range caching
- Enforcement logic

**Architectural Decision Unlocked:**
→ Control ranges: implement or enhance?

---

### E-03: How are controls exposed to Kotlin?

**Why It Matters:**
The plan requires "typed controls with units."

**Investigation:**
```bash
grep -rn 'setExposure\|setGain\|setBrightness\|setContrast' $KOTLIN_PATH
grep -rn 'CameraControl\|ControlValue' $KOTLIN_PATH
```

**Expected Evidence:**
- Control API surface
- Type safety level
- Unit handling

**Architectural Decision Unlocked:**
→ Control API: redesign or enhance?

---

### E-04: Is there async control handling?

**Why It Matters:**
UVC 1.5 allows async controls. CVE-2024-58002 relates to this.

**Investigation:**
```bash
grep -rn 'async\|interrupt.*endpoint\|status.*interrupt' $JNI_PATH
grep -rn 'VS_CONTROL\|VC_REQUEST' $JNI_PATH
```

**Expected Evidence:**
- Async control code
- Interrupt endpoint handling
- Status polling

**Architectural Decision Unlocked:**
→ Async controls: security review needed?

---

### E-05: Are there any vendor-specific control workarounds?

**Why It Matters:**
The plan requires "per-vendor quirk packs."

**Investigation:**
```bash
grep -rn 'quirk\|workaround\|vendor\|logitech\|elgato' $JNI_PATH
grep -rn 'delay.*control\|retry.*control' $JNI_PATH
```

**Expected Evidence:**
- Vendor-specific code
- Timing workarounds
- Known quirks

**Architectural Decision Unlocked:**
→ Quirk system: exists or build?

---

## Category F: Memory & Threading

These questions determine zero-copy and concurrency feasibility.

### F-01: Is AHardwareBuffer currently used?

**Why It Matters:**
The plan heavily relies on AHardwareBuffer for zero-copy.

**Investigation:**
```bash
grep -rn 'AHardwareBuffer\|hardware_buffer\|HardwareBuffer' $JNI_PATH $KOTLIN_PATH
find $PROJECT_ROOT -name "*.cpp" -exec grep -l 'android/hardware_buffer' {} \;
```

**Expected Evidence:**
- AHardwareBuffer allocation
- Usage patterns
- Format selection

**Architectural Decision Unlocked:**
→ AHardwareBuffer: already used or needs implementation?

---

### F-02: What is the current copy count in frame path?

**Why It Matters:**
The plan requires "no CPU pixel work where possible."

**Investigation:**
```bash
grep -rn 'memcpy\|memmove\|std::copy' $JNI_PATH
# Count memcpy in frame-related files
```

**Expected Evidence:**
- Copy locations
- Copy sizes
- Copy necessity

**Architectural Decision Unlocked:**
→ Zero-copy: how much refactoring needed?

---

### F-03: What synchronization primitives are used?

**Why It Matters:**
The plan requires "lock-free where possible."

**Investigation:**
```bash
grep -rn 'mutex\|lock\|atomic\|condition_variable' $JNI_PATH
grep -rn 'synchronized\|Mutex\|Lock' $KOTLIN_PATH
```

**Expected Evidence:**
- Lock types
- Lock granularity
- Atomic usage

**Architectural Decision Unlocked:**
→ Concurrency: refactor or redesign?

---

### F-04: Is there thread priority management?

**Why It Matters:**
The plan requires "USB read threads with prioritized consistent cadence."

**Investigation:**
```bash
grep -rn 'priority\|sched_param\|SCHED_\|nice' $JNI_PATH
grep -rn 'threadPriority\|Priority' $KOTLIN_PATH
```

**Expected Evidence:**
- Priority settings
- Scheduler hints
- Real-time considerations

**Architectural Decision Unlocked:**
→ Thread priority: implement or enhance?

---

### F-05: How is backpressure handled?

**Why It Matters:**
The plan requires "if any queue grows, you choose between drop/reduce/throttle."

**Investigation:**
```bash
grep -rn 'drop\|discard\|full\|overflow\|backpressure' $JNI_PATH
grep -rn 'queue.*size\|buffer.*count' $JNI_PATH
```

**Expected Evidence:**
- Queue limits
- Drop policy
- Throttle mechanism

**Architectural Decision Unlocked:**
→ Backpressure: implement or enhance?

---

### F-06: What is the memory ownership model?

**Why It Matters:**
The plan requires clear ownership semantics.

**Investigation:**
```bash
grep -rn 'unique_ptr\|shared_ptr\|make_unique\|make_shared' $JNI_PATH
grep -rn 'new\s\|delete\s\|malloc\|free' $JNI_PATH
```

**Expected Evidence:**
- Smart pointer usage
- Manual memory management
- Ownership transfer patterns

**Architectural Decision Unlocked:**
→ Memory: modern or needs refactoring?

---

## Category G: Build System

These questions determine build migration scope.

### G-01: What build system is currently used?

**Why It Matters:**
The plan assumes Android.mk needs migration.

**Investigation:**
```bash
find $PROJECT_ROOT -name "Android.mk" -o -name "Application.mk" -o -name "CMakeLists.txt"
find $PROJECT_ROOT -name "*.gradle*" -exec grep -l 'externalNativeBuild' {} \;
```

**Expected Evidence:**
- Build file locations
- Build system type
- Gradle integration

**Architectural Decision Unlocked:**
→ OPP-013: Is CMake migration needed?

---

### G-02: What NDK version is targeted?

**Why It Matters:**
The plan requires NDK r28+ for 16KB page size compliance.

**Investigation:**
```bash
grep -rn 'NDK_\|ndk\|minSdkVersion\|compileSdk' $PROJECT_ROOT --include="*.gradle*" --include="*.mk"
```

**Expected Evidence:**
- NDK version
- Min SDK version
- Target SDK version

**Architectural Decision Unlocked:**
→ NDK upgrade scope

---

### G-03: What C++ standard is used?

**Why It Matters:**
The plan assumes C++23 for std::expected, std::span, etc.

**Investigation:**
```bash
grep -rn 'CMAKE_CXX_STANDARD\|APP_CPPFLAGS.*std=\|-std=c++' $PROJECT_ROOT --include="*.mk" --include="CMakeLists.txt"
```

**Expected Evidence:**
- C++ standard setting
- Feature usage (expected, span, jthread)

**Architectural Decision Unlocked:**
→ C++ standard upgrade needed?

---

### G-04: How are dependencies managed?

**Why It Matters:**
The plan specifies "FetchContent for dependencies."

**Investigation:**
```bash
grep -rn 'FetchContent\|ExternalProject\|import-module\|PREBUILT' $PROJECT_ROOT --include="*.mk" --include="CMakeLists.txt"
find $PROJECT_ROOT -name "*.a" -o -name "*.so" | head -20
```

**Expected Evidence:**
- Dependency mechanism
- Prebuilt libraries
- Source vs. binary deps

**Architectural Decision Unlocked:**
→ Dependency management scope

---

### G-05: Are security flags properly configured?

**Why It Matters:**
The plan requires NDK security defaults verification.

**Investigation:**
```bash
grep -rn 'fstack-protector\|FORTIFY_SOURCE\|fPIC\|fPIE' $PROJECT_ROOT --include="*.mk" --include="CMakeLists.txt"
grep -rn '\-fno-' $PROJECT_ROOT --include="*.mk" --include="CMakeLists.txt"
```

**Expected Evidence:**
- Security flags present
- Any disabled protections
- Page size handling

**Architectural Decision Unlocked:**
→ Security hardening scope

---

## Investigation Execution Plan

### Phase 1: Transport & libuvc (Questions A-01 to B-10)

**Duration:** 2-3 hours
**Output:** INVESTIGATION-001-transport-libuvc.md
**Critical Decisions:**
- Fork vs. wrapper vs. rewrite
- Isochronous feasibility
- FD injection status

### Phase 2: Payload & Decode (Questions C-01 to C-07)

**Duration:** 1-2 hours
**Output:** INVESTIGATION-002-payload-pipeline.md
**Critical Decisions:**
- Format support matrix
- MediaCodec integration
- GPU pipeline status

### Phase 3: Timestamps (Questions D-01 to D-06)

**Duration:** 1-2 hours
**Output:** INVESTIGATION-003-timestamps.md
**Critical Decisions:**
- PTS/SCR extraction point
- Clock sync design
- Timestamp API

### Phase 4: Controls (Questions E-01 to E-05)

**Duration:** 1 hour
**Output:** INVESTIGATION-004-controls.md
**Critical Decisions:**
- GET_INFO implementation
- XU framework scope
- Quirk system design

### Phase 5: Memory & Threading (Questions F-01 to F-06)

**Duration:** 1-2 hours
**Output:** INVESTIGATION-005-memory-threading.md
**Critical Decisions:**
- Zero-copy gap
- Lock-free feasibility
- Thread model

### Phase 6: Build System (Questions G-01 to G-05)

**Duration:** 1 hour
**Output:** INVESTIGATION-006-build-system.md
**Critical Decisions:**
- Migration scope
- NDK upgrade
- Security hardening

---

## Summary: What These Questions Unlock

| Question Set | Architectural Decision |
|--------------|----------------------|
| A (Transport) | Bulk-first vs. isochronous strategy |
| B (libuvc) | Fork / wrapper / rewrite decision |
| C (Payload) | Format support & decode paths |
| D (Timestamps) | PTS/SCR extraction feasibility |
| E (Controls) | Control plane architecture |
| F (Memory) | Zero-copy & concurrency design |
| G (Build) | Migration scope & timeline |

**After answering all 47 questions, we will have evidence-based answers for every major architectural decision in the 2026 plan.**

---

*End of INVESTIGATION-001*
