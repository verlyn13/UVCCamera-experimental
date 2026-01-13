# INVENTORY-001: Directory Structure

**Audit:** AUDIT-001 UVCCamera Codebase Reconnaissance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Summary Statistics

| Metric | Value |
|--------|-------|
| Total Directories | 86 |
| Total Files | 886 |
| Empty Directories | 0 |
| Depth Levels | 6 (max) |

---

## Top-Level Structure

```
jni/
├── Android.mk              # Root build orchestration (includes all submodules)
├── Application.mk          # NDK application settings (ABI, STL, optimization)
├── localdefines.h          # Local preprocessor definitions
├── utilbase.h              # Base utility macros and logging
├── UVCCamera/              # Main JNI implementation (PRIMARY TARGET)
├── libuvc/                 # USB Video Class protocol library
├── libusb/                 # USB device communication library
├── libjpeg-turbo-1.5.0/    # JPEG encoding/decoding (SIMD optimized)
├── rapidjson/              # JSON parsing (header-only)
└── test/                   # Native test suite with mocks
```

---

## Directory Classification

| Directory | Classification | Purpose | File Count |
|-----------|---------------|---------|------------|
| **UVCCamera/** | Core JNI | Main camera implementation, JNI bridge, ring buffer | 51 |
| **UVCCamera/pipeline/** | Core JNI | Frame processing pipeline implementations | 22 |
| **libuvc/** | Dependency | USB Video Class protocol implementation | ~30 |
| **libuvc/src/** | Dependency | UVC source files (ctrl, device, frame, stream) | 17 |
| **libuvc/include/** | Dependency | Public UVC API headers | 3 |
| **libusb/** | Dependency | USB device access library | ~80 |
| **libusb/libusb/** | Dependency | Core USB implementation | ~25 |
| **libusb/libusb/os/** | Dependency | Platform-specific USB implementations | ~20 |
| **libjpeg-turbo-1.5.0/** | Dependency | JPEG codec with SIMD acceleration | ~200 |
| **libjpeg-turbo-1.5.0/simd/** | Dependency | Architecture-specific SIMD assembly | ~100 |
| **rapidjson/** | Dependency | JSON library (header-only, mostly docs) | ~50 |
| **rapidjson/include/** | Dependency | Public JSON API headers | ~20 |
| **test/** | Testing | Native unit tests with Android mocks | 7 |

---

## Detailed Component Breakdown

### 1. UVCCamera/ (Core Implementation)

```
UVCCamera/
├── pipeline/                    # Frame processing pipelines (22 files)
│   ├── IPipeline.cpp/h         # Abstract pipeline interface
│   ├── AbstractBufferedPipeline.cpp/h
│   ├── SimpleBufferedPipeline.cpp/h
│   ├── SQLiteBufferedPipeline.cpp/h
│   ├── CallbackPipeline.cpp/h
│   ├── PreviewPipeline.cpp/h
│   ├── PublisherPipeline.cpp/h
│   ├── ConvertPipeline.cpp/h
│   ├── DistributePipeline.cpp/h
│   ├── CaptureBasePipeline.cpp/h
│   └── pipeline_helper.cpp/h
├── _onload.cpp/h               # JNI_OnLoad initialization
├── UVCCamera.cpp/h             # Main camera class
├── UVCPreview.cpp/h            # Preview/conversion thread (LARGEST FILE)
├── FrameBufferRing.cpp/h       # AHardwareBuffer triple ring
├── FrameBufferJNI.cpp          # Ring buffer JNI bindings
├── HandleManager.cpp/h         # Slot-based ref counting (MODERN C++)
├── Parameters.cpp/h            # Camera parameter management
├── StreamTelemetry.h           # Telemetry counters (37 fields)
├── FrameSlotMetadata.h         # Per-frame metadata
├── OutputMode.h                # Frame routing enum
├── LayoutContract.cpp/h        # ABI validation
├── EGLImageHelperJNI.cpp       # OpenGL/EGL integration
├── UVCButtonCallback.cpp/h     # Hardware button handling
├── UVCStatusCallback.cpp/h     # Status event callbacks
├── UVCReadinessCallback.cpp/h  # Readiness state callbacks
├── serenegiant_usb_UVCCamera.cpp  # Additional JNI methods
├── utilbase.cpp                # Utility implementations
├── libUVCCamera.h              # Library header
├── objectarray.h               # Array utilities
└── Android.mk                  # Build configuration
```

### 2. libuvc/ (UVC Protocol)

```
libuvc/
├── android/jni/                # Android build config
│   └── Android.mk
├── cameras/                    # Device-specific configs (6 files)
├── include/
│   ├── libuvc/
│   │   ├── libuvc.h           # Public API
│   │   └── libuvc_internal.h  # Internal definitions
│   └── utlist.h               # Linked list macros
├── src/
│   ├── ctrl.c                 # UVC control commands
│   ├── device.c               # Device management
│   ├── diag.c                 # Diagnostics
│   ├── frame.c                # Frame handling
│   ├── frame-mjpeg.c          # MJPEG decompression
│   ├── init.c                 # Initialization
│   ├── stream.c               # USB streaming
│   ├── misc.c                 # Utilities
│   └── *_original.c           # Original versions (preserved)
└── CMakeLists.txt             # CMake config (alternative build)
```

### 3. libusb/ (USB Access)

```
libusb/
├── android/
│   └── jni/
│       ├── Android.mk
│       └── Application.mk
├── libusb/
│   ├── os/
│   │   ├── android_usbfs.c    # Android-specific USB filesystem
│   │   ├── android_netlink.c  # Android netlink integration
│   │   ├── linux_usbfs.c      # Linux USB filesystem
│   │   ├── poll_posix.c       # POSIX poll implementation
│   │   └── threads_posix.c    # POSIX threads
│   ├── core.c                 # Core USB functionality
│   ├── descriptor.c           # USB descriptor parsing
│   ├── hotplug.c/h            # Hotplug detection
│   ├── io.c                   # I/O operations
│   ├── sync.c                 # Synchronous operations
│   ├── libusb.h               # Public API
│   └── libusbi.h              # Internal header
├── examples/                   # Example applications
├── msvc/                       # MSVC build configs
└── Xcode/                      # Xcode project
```

### 4. libjpeg-turbo-1.5.0/ (JPEG Codec)

```
libjpeg-turbo-1.5.0/
├── include/                    # Generated config headers
├── simd/                       # SIMD implementations (~100 files)
│   ├── jsimd_arm_neon.S       # ARM NEON assembly
│   ├── jsimd_arm64_neon.S     # ARM64 NEON assembly
│   ├── jsimd_i386.c           # x86 32-bit
│   ├── jsimd_x86_64.c         # x86 64-bit
│   └── *.asm                  # MMX/SSE/SSE2 assembly
├── java/                       # Java JNI bindings
├── *.c                         # Core JPEG implementation
├── *.h                         # Headers
├── Android.mk                  # Android build
└── CMakeLists.txt             # CMake build
```

### 5. rapidjson/ (JSON Library)

```
rapidjson/
├── include/rapidjson/          # Header-only library
│   ├── document.h             # DOM API
│   ├── reader.h               # SAX reader
│   ├── writer.h               # JSON writer
│   └── *.h                    # Other headers
├── doc/                        # Documentation
├── example/                    # Usage examples
└── test/                       # Test suite
```

### 6. test/ (Native Tests)

```
test/
├── include/
│   ├── ContractVerification.h  # ABI contract verification
│   └── TelemetryContract.h     # Telemetry layout verification
├── mocks/
│   ├── AndroidApiMocks.cpp     # Mock Android APIs
│   └── AndroidApiMocks.h
├── tests/
│   ├── FrameBufferRingTest.cpp # Ring buffer tests
│   ├── ContractTest.cpp        # Contract verification tests
│   └── StreamTelemetryTest.cpp # Telemetry tests
└── CMakeLists.txt              # CMake test build
```

---

## Anomalies and Observations

### No Anomalies Found
- No empty directories
- No orphaned files
- All directories have clear purpose

### Notable Observations

1. **Preserved Original Files**: libuvc and libusb contain `*_original.c` files alongside modified versions. This provides change tracking for upstream synchronization.

2. **Dual Build Systems**: Both `Android.mk` (ndk-build) and `CMakeLists.txt` (CMake) are present. The project uses ndk-build for production, CMake for testing.

3. **SIMD Assembly**: libjpeg-turbo contains ~100 SIMD assembly files for multiple architectures (ARM NEON, x86 MMX/SSE/SSE2, PowerPC Altivec, MIPS DSP).

4. **Header-Only rapidjson**: The rapidjson library is header-only; no compilation needed.

5. **Version in Path**: libjpeg-turbo uses version 1.5.0 (2016). This is outdated - current is 3.0+.

---

## Raw Data

Full tree output: `raw/directory-tree.txt` (886 files)

---

*End of INVENTORY-001*
