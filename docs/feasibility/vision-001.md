ScopeCam Vision: First-Class Modern UVC Camera Library

  The Ideal End State

  This document describes the aspirational technical vision for what the UVCCamera/libuvc implementation could become - a reference implementation for modern USB Video Class camera support on Android.

  ---
  1. Core Vision

  1.1 Mission Statement

  ScopeCam's libuvc should be the definitive open-source implementation of UVC 1.5 on Android - providing:
  - Sub-frame latency from USB to display
  - Hardware-accelerated paths for all common formats
  - Complete UVC 1.5 specification compliance
  - Zero-configuration operation for standard cameras
  - Deep customization for specialized hardware

  1.2 Design Principles
  Principle: Zero-Copy Where Possible
  Description: Frame data flows from USB DMA to GPU texture without CPU copies
  ────────────────────────────────────────
  Principle: Timestamp-First
  Description: Every frame carries authoritative device timestamps, properly synchronized
  ────────────────────────────────────────
  Principle: Fail Gracefully
  Description: Degrade to lower quality rather than crash; always provide diagnostics
  ────────────────────────────────────────
  Principle: Observable Everything
  Description: Every state transition, every metric, every error - visible and queryable
  ────────────────────────────────────────
  Principle: Layered Abstraction
  Description: Raw UVC for experts, high-level API for app developers
  ---
  2. Architecture Vision

  2.1 Idealized Stack

  ┌─────────────────────────────────────────────────────────────────────────────────┐
  │                              APPLICATION LAYER                                   │
  │  ┌─────────────────────────────────────────────────────────────────────────────┐│
  │  │  Kotlin/Java API                                                             ││
  │  │  • CameraManager - Discovery, lifecycle, permissions                         ││
  │  │  • CameraSession - Active streaming session                                  ││
  │  │  • FrameReceiver - Type-safe frame delivery (Surface, Bitmap, ByteBuffer)    ││
  │  │  • ControlPanel - Camera controls with capability introspection              ││
  │  │  • Telemetry - Real-time performance metrics                                 ││
  │  └─────────────────────────────────────────────────────────────────────────────┘│
  ├─────────────────────────────────────────────────────────────────────────────────┤
  │                              NATIVE BRIDGE LAYER                                 │
  │  ┌─────────────────────────────────────────────────────────────────────────────┐│
  │  │  JNI + C++ Orchestration                                                     ││
  │  │  • UVCCameraManager - Native camera lifecycle                                ││
  │  │  • FramePipeline - Format conversion, zero-copy routing                      ││
  │  │  • ControlProxy - Type-safe control access                                   ││
  │  │  • TelemetryCollector - Performance instrumentation                          ││
  │  └─────────────────────────────────────────────────────────────────────────────┘│
  ├─────────────────────────────────────────────────────────────────────────────────┤
  │                              UVC PROTOCOL LAYER                                  │
  │  ┌─────────────────────────────────────────────────────────────────────────────┐│
  │  │  Modern libuvc (C with C++ Wrapper)                                          ││
  │  │  • Full UVC 1.5 compliance                                                   ││
  │  │  • PTS/SCR timestamp extraction with clock sync                              ││
  │  │  • All payload formats (Uncompressed, MJPEG, H.264, HEVC)                    ││
  │  │  • Extension Unit framework with vendor protocol support                     ││
  │  │  • GET_INFO capability introspection                                         ││
  │  │  • Structured error handling with recovery strategies                        ││
  │  └─────────────────────────────────────────────────────────────────────────────┘│
  ├─────────────────────────────────────────────────────────────────────────────────┤
  │                              USB TRANSPORT LAYER                                 │
  │  ┌─────────────────────────────────────────────────────────────────────────────┐│
  │  │  libusb (Android-optimized fork)                                             ││
  │  │  • Isochronous transfers with optimal packet scheduling                      ││
  │  │  • Bulk transfer fallback with adaptive throttling                           ││
  │  │  • Hot-plug detection and graceful disconnect handling                       ││
  │  │  • USB 3.x superspeed support                                                ││
  │  └─────────────────────────────────────────────────────────────────────────────┘│
  ├─────────────────────────────────────────────────────────────────────────────────┤
  │                              HARDWARE ACCELERATION                               │
  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐              │
  │  │  AHardwareBuffer │  │   MediaCodec     │  │   GPU Compute    │              │
  │  │  Zero-copy DMA   │  │  H.264/HEVC HW   │  │  Color convert   │              │
  │  │  Surface output  │  │  decode          │  │  YUYV→RGBA       │              │
  │  └──────────────────┘  └──────────────────┘  └──────────────────┘              │
  └─────────────────────────────────────────────────────────────────────────────────┘

  2.2 Data Flow - Zero-Copy Path (Ideal)

  USB DMA Buffer ──────────────────────────────────────────────────────────────────►
         │
         │ [1] Isochronous transfer completes
         ▼
  ┌─────────────────┐
  │ Payload Parser  │  • Extract PTS/SCR from header
  │ (stream.c)      │  • Detect frame boundaries (EOF bit)
  │                 │  • Track sequence numbers
  └────────┬────────┘
           │
           │ [2] Complete frame assembled
           ▼
  ┌─────────────────┐
  │ Frame Router    │  • Route based on format + consumer
  │                 │  • MJPEG → libjpeg-turbo OR MediaCodec
  │                 │  • H.264 → MediaCodec (mandatory)
  │                 │  • YUYV → GPU shader OR CPU fallback
  └────────┬────────┘
           │
           │ [3] Format-specific decode
           ├──────────────────────────────────────────────┐
           │                                               │
           ▼                                               ▼
  ┌─────────────────┐                           ┌─────────────────┐
  │ MediaCodec      │                           │ GPU Shader      │
  │ (H.264/HEVC)    │                           │ (YUYV→RGBA)     │
  │                 │                           │                 │
  │ Input: NAL+PTS  │                           │ Input: YUYV tex │
  │ Output: Surface │                           │ Output: RGBA tex│
  └────────┬────────┘                           └────────┬────────┘
           │                                              │
           │ [4] Hardware renders directly to Surface     │
           ▼                                              ▼
  ┌─────────────────────────────────────────────────────────────┐
  │                    ANativeWindow / Surface                   │
  │                                                              │
  │  • Compositor picks up buffer                                │
  │  • Display with correct PTS timing                           │
  │  • No CPU touch of pixel data                                │
  └─────────────────────────────────────────────────────────────┘

  Key Achievement: Pixel data never touched by CPU in optimal path. USB DMA → GPU texture → Display compositor.

  ---
  3. Timestamp Perfection

  3.1 The Timestamp Dream

  Every frame delivered to the application carries:

  struct FrameMetadata {
      // Device timestamps (from UVC payload header)
      uint32_t devicePts;           // Raw PTS from camera (device clock units)
      uint32_t deviceScr;           // Raw SCR from camera
      uint16_t scrSofCounter;       // SOF counter from SCR

      // Synchronized timestamps
      int64_t systemTimeNs;         // CLOCK_MONOTONIC when frame received
      int64_t presentationTimeNs;   // Ideal display time (PTS mapped to system clock)
      int64_t captureTimeNs;        // Estimated actual capture moment

      // Synchronization quality
      float clockDriftPpm;          // Device clock drift from system clock
      float syncConfidence;         // 0.0-1.0 confidence in sync accuracy
      uint32_t syncSampleCount;     // Samples in linear regression

      // Frame identity
      uint64_t frameNumber;         // Monotonic frame counter
      uint32_t sequence;            // UVC sequence number (wraps at 2^32)
  };

  3.2 Clock Synchronization Algorithm

  class ClockSynchronizer {
  public:
      // Called for each frame with PTS
      void addSample(uint32_t devicePts, int64_t systemTimeNs) {
          // Unwrap PTS (handle 32-bit wraparound)
          uint64_t unwrappedPts = unwrapPts(devicePts);

          // Add to linear regression
          mRegression.addPoint(unwrappedPts, systemTimeNs);

          // Update clock model
          if (mRegression.sampleCount() >= MIN_SAMPLES) {
              mSlope = mRegression.slope();      // ns per PTS tick
              mOffset = mRegression.intercept(); // system time at PTS=0
              mDriftPpm = (mSlope - mNominalSlope) / mNominalSlope * 1e6;

              // Kalman filter for smooth updates
              mKalman.update(mSlope, mOffset);
          }
      }

      // Convert device PTS to system time
      int64_t ptsToSystemTime(uint32_t devicePts) const {
          uint64_t unwrapped = unwrapPts(devicePts);
          return mKalman.slope() * unwrapped + mKalman.offset();
      }

      // Estimate capture time (PTS - sensor integration time)
      int64_t ptsToCaptureTime(uint32_t devicePts, int64_t exposureNs) const {
          return ptsToSystemTime(devicePts) - exposureNs / 2;
      }

  private:
      LinearRegression mRegression;
      KalmanFilter1D mKalman;
      double mSlope, mOffset;
      double mNominalSlope;  // From dwClockFrequency
      double mDriftPpm;
  };

  3.3 Timestamp Accuracy Target
  ┌───────────────────────┬────────────┬─────────────────────────────────────┐
  │        Metric         │   Target   │                Notes                │
  ├───────────────────────┼────────────┼─────────────────────────────────────┤
  │ Sync convergence time │ < 1 second │ After 30 frames at 30fps            │
  ├───────────────────────┼────────────┼─────────────────────────────────────┤
  │ Steady-state accuracy │ < 1ms      │ After convergence                   │
  ├───────────────────────┼────────────┼─────────────────────────────────────┤
  │ Drift tracking        │ < 10 ppm   │ Typical USB camera crystal accuracy │
  ├───────────────────────┼────────────┼─────────────────────────────────────┤
  │ PTS jitter handling   │ < 2ms      │ Outlier rejection                   │
  └───────────────────────┴────────────┴─────────────────────────────────────┘
  ---
  4. Control Plane Perfection

  4.1 Capability Introspection

  Every control is fully introspectable before use:

  // Kotlin API
  val brightness = camera.controls.brightness

  // Full capability info available
  println("Brightness control:")
  println("  Supported: ${brightness.isSupported}")
  println("  Readable: ${brightness.isReadable}")
  println("  Writable: ${brightness.isWritable}")
  println("  Auto-capable: ${brightness.supportsAuto}")
  println("  Range: ${brightness.min}..${brightness.max}")
  println("  Step: ${brightness.step}")
  println("  Default: ${brightness.default}")
  println("  Current: ${brightness.current}")

  // Type-safe modification
  brightness.value = 50  // Validated against range
  brightness.auto = true // Only if supportsAuto

  4.2 Native Control Interface

  // C++ API with full GET_INFO support
  class UVCControl {
  public:
      // Capability query (uses GET_INFO)
      struct Capabilities {
          bool supportsGet : 1;
          bool supportsSet : 1;
          bool supportsGetMin : 1;
          bool supportsGetMax : 1;
          bool supportsGetRes : 1;
          bool supportsGetDef : 1;
          bool disabled : 1;
          bool autoUpdateCapable : 1;
          bool asynchronous : 1;
      };

      Capabilities getCapabilities() const;

      // Type-safe value access
      template<typename T>
      Result<T> get() const;

      template<typename T>
      Result<void> set(T value);

      // Range query
      template<typename T>
      Result<Range<T>> getRange() const;

      // Auto mode (for controls that support it)
      Result<bool> isAuto() const;
      Result<void> setAuto(bool enable);

  private:
      uint8_t mUnitId;
      uint8_t mSelector;
      uint16_t mSize;
      Capabilities mCaps;  // Cached from GET_INFO
  };

  4.3 Control Categories

  class CameraControls {
  public:
      // Camera Terminal Controls (CT)
      Control<ScanningMode> scanningMode;
      Control<AutoExposureMode> autoExposureMode;
      Control<uint8_t> autoExposurePriority;
      Control<uint32_t> exposureTimeAbsolute;  // 100μs units
      Control<int8_t> exposureTimeRelative;
      Control<uint16_t> focusAbsolute;
      Control<int8_t> focusRelative;
      Control<bool> focusAuto;
      Control<uint16_t> irisAbsolute;
      Control<int8_t> irisRelative;
      Control<uint16_t> zoomAbsolute;
      Control<int8_t> zoomRelative;
      Control<PanTilt> panTiltAbsolute;
      Control<PanTiltRelative> panTiltRelative;
      Control<uint8_t> rollAbsolute;
      Control<int8_t> rollRelative;
      Control<uint8_t> privacy;
      Control<bool> focusSimple;
      Control<DigitalWindow> digitalWindow;
      Control<RegionOfInterest> regionOfInterest;

      // Processing Unit Controls (PU)
      Control<uint16_t> backlightCompensation;
      Control<int16_t> brightness;
      Control<uint16_t> contrast;
      Control<uint16_t> gain;
      Control<PowerLineFrequency> powerLineFrequency;
      Control<int16_t> hue;
      Control<bool> hueAuto;
      Control<uint16_t> saturation;
      Control<uint16_t> sharpness;
      Control<uint16_t> gamma;
      Control<uint16_t> whiteBalanceTemperature;
      Control<bool> whiteBalanceTemperatureAuto;
      Control<WhiteBalanceComponent> whiteBalanceComponent;
      Control<bool> whiteBalanceComponentAuto;
      Control<uint16_t> digitalMultiplier;
      Control<uint16_t> digitalMultiplierLimit;
      Control<AnalogVideoStandard> analogVideoStandard;
      Control<AnalogVideoLockStatus> analogVideoLockStatus;
      Control<uint16_t> contrastAuto;
  };

  ---
  5. Extension Unit Framework

  5.1 Vendor-Agnostic XU Access

  class ExtensionUnit {
  public:
      // Identification
      const Guid& guid() const;
      uint8_t unitId() const;
      const std::string& name() const;  // From string descriptor if available

      // Control enumeration
      std::vector<XUControl> controls() const;

      // Generic typed access
      template<typename T>
      Result<T> get(uint8_t selector) const;

      template<typename T>
      Result<void> set(uint8_t selector, const T& value);

      // Raw access for unknown controls
      Result<std::vector<uint8_t>> getRaw(uint8_t selector, size_t maxLen) const;
      Result<void> setRaw(uint8_t selector, const std::vector<uint8_t>& data);
  };

  5.2 Vendor Protocol Plugins

  // Base class for vendor-specific XU interpreters
  class VendorXUProtocol {
  public:
      virtual ~VendorXUProtocol() = default;

      // Factory registration
      static void registerProtocol(const Guid& guid,
                                   std::unique_ptr<VendorXUProtocol> protocol);
      static VendorXUProtocol* findProtocol(const Guid& guid);

      // Vendor implementation provides these
      virtual std::string vendorName() const = 0;
      virtual std::vector<XUControlDescriptor> describeControls() const = 0;
      virtual Result<std::any> interpretGet(uint8_t selector,
                                            const std::vector<uint8_t>& data) const = 0;
      virtual Result<std::vector<uint8_t>> formatSet(uint8_t selector,
                                                      const std::any& value) const = 0;
  };

  // Example: Logitech UVC Extension
  class LogitechXUProtocol : public VendorXUProtocol {
  public:
      static constexpr Guid LOGITECH_XU_GUID = {...};

      std::string vendorName() const override { return "Logitech"; }

      std::vector<XUControlDescriptor> describeControls() const override {
          return {
              {0x01, "LED Control", TypeDescriptor::uint8()},
              {0x02, "Motor Pan/Tilt", TypeDescriptor::struct_<PanTilt>()},
              {0x03, "Focus Mode", TypeDescriptor::enum_<FocusMode>()},
              // ... more Logitech-specific controls
          };
      }

      // ... interpret/format implementations
  };

  // Auto-registration
  REGISTER_XU_PROTOCOL(LogitechXUProtocol::LOGITECH_XU_GUID, LogitechXUProtocol);

  ---
  6. Format & Resolution Negotiation

  6.1 Smart Format Selection

  class FormatNegotiator {
  public:
      struct Request {
          uint32_t preferredWidth = 1920;
          uint32_t preferredHeight = 1080;
          float preferredFps = 30.0f;

          // Priority order for formats
          std::vector<FrameFormat> formatPreference = {
              FrameFormat::MJPEG,    // Best quality/bandwidth
              FrameFormat::H264,     // Hardware decode
              FrameFormat::YUYV,     // Uncompressed
          };

          // Constraints
          uint32_t minWidth = 640;
          uint32_t maxWidth = 4096;
          uint32_t minFps = 15;
          float maxBandwidthMbps = 400.0f;  // USB 2.0 high-speed limit
      };

      struct Result {
          // Selected format
          uint8_t formatIndex;
          uint8_t frameIndex;
          uint32_t width;
          uint32_t height;
          uint32_t frameInterval;  // 100ns units
          float actualFps;
          FrameFormat format;

          // Bandwidth analysis
          float estimatedBandwidthMbps;
          uint8_t recommendedAltSetting;

          // Why this was selected
          std::string selectionReason;
          std::vector<std::string> rejectedAlternatives;
      };

      Result negotiate(const Request& request,
                       const std::vector<FormatDescriptor>& available);
  };

  6.2 Dynamic Resolution Switching

  class StreamSession {
  public:
      // Runtime resolution change (if camera supports)
      Result<void> changeResolution(uint32_t width, uint32_t height) {
          // 1. Negotiate new format
          auto newFormat = mNegotiator.negotiate({width, height, mCurrentFps},
                                                  mAvailableFormats);

          // 2. If same format index, might be able to hot-switch
          if (newFormat.formatIndex == mCurrentFormat.formatIndex) {
              return hotSwitchFrame(newFormat.frameIndex);
          }

          // 3. Otherwise, full restart with minimal gap
          return seamlessRestart(newFormat);
      }

  private:
      Result<void> hotSwitchFrame(uint8_t newFrameIndex) {
          // Use PROBE/COMMIT to change frame without stopping stream
          // Some cameras support this for minimal latency
      }

      Result<void> seamlessRestart(const FormatResult& newFormat) {
          // 1. Start new stream in parallel
          // 2. Wait for first frame from new stream
          // 3. Atomic switch of frame delivery
          // 4. Stop old stream
          // Gap: typically < 100ms
      }
  };

  ---
  7. Error Handling & Recovery

  7.1 Structured Error Taxonomy

  enum class UVCError {
      // Success
      Success = 0,

      // Device errors
      DeviceNotFound,
      DeviceDisconnected,
      DeviceBusy,
      DeviceAccessDenied,

      // Protocol errors
      StallOnControl,
      InvalidDescriptor,
      UnsupportedFormat,
      NegotiationFailed,

      // Streaming errors
      BandwidthExceeded,
      IsochronousOverrun,
      FrameCorrupted,
      TimestampDiscontinuity,

      // Control errors
      ControlNotSupported,
      ControlOutOfRange,
      ControlReadOnly,
      ControlWriteOnly,

      // Resource errors
      OutOfMemory,
      BufferOverflow,
      Timeout,

      // Internal errors
      InternalError,
      NotImplemented,
  };

  struct ErrorContext {
      UVCError code;
      std::string message;
      std::string source;         // Function/component that failed
      int64_t timestampNs;

      // Chain of causes
      std::optional<ErrorContext> cause;

      // Recovery suggestion
      enum class Recovery {
          None,           // Unrecoverable
          Retry,          // Transient, retry same operation
          Reconnect,      // Disconnect and reconnect device
          LowerQuality,   // Try lower bandwidth settings
          Fallback,       // Use alternative approach
      };
      Recovery suggestedRecovery;
      std::string recoveryDetails;
  };

  7.2 Automatic Recovery Strategies

  class StreamRecovery {
  public:
      // Automatic recovery for transient errors
      void onStreamError(const ErrorContext& error) {
          switch (error.suggestedRecovery) {
              case Recovery::Retry:
                  if (mRetryCount < MAX_RETRIES) {
                      mRetryCount++;
                      scheduleRetry(RETRY_DELAY_MS);
                  }
                  break;

              case Recovery::LowerQuality:
                  // Try lower resolution or frame rate
                  auto fallback = mNegotiator.negotiateFallback(mCurrentFormat);
                  if (fallback) {
                      mFallbackLevel++;
                      applyFallback(*fallback);
                      notifyFallback(*fallback);
                  }
                  break;

              case Recovery::Reconnect:
                  // Full device reset
                  scheduleReconnect();
                  break;

              case Recovery::Fallback:
                  // Switch from isochronous to bulk, etc.
                  tryAlternativeTransport();
                  break;

              case Recovery::None:
                  // Unrecoverable - notify application
                  notifyFatalError(error);
                  break;
          }
      }

  private:
      int mRetryCount = 0;
      int mFallbackLevel = 0;
      static constexpr int MAX_RETRIES = 3;
      static constexpr int RETRY_DELAY_MS = 100;
  };

  ---
  8. Telemetry & Observability

  8.1 Comprehensive Metrics

  struct StreamTelemetry {
      // === Frame Counters ===
      std::atomic<uint64_t> framesReceived{0};
      std::atomic<uint64_t> framesDelivered{0};
      std::atomic<uint64_t> framesDropped{0};
      std::atomic<uint64_t> framesCorrupted{0};

      // === Timing (microseconds) ===
      std::atomic<int64_t> lastFrameLatencyUs{0};    // USB receive → app delivery
      std::atomic<int64_t> avgFrameLatencyUs{0};     // EMA
      std::atomic<int64_t> minFrameLatencyUs{INT64_MAX};
      std::atomic<int64_t> maxFrameLatencyUs{0};

      std::atomic<int64_t> lastDecodeTimeUs{0};      // Decode/convert time
      std::atomic<int64_t> avgDecodeTimeUs{0};

      std::atomic<int64_t> lastRenderTimeUs{0};      // Render to surface time
      std::atomic<int64_t> avgRenderTimeUs{0};

      // === USB Transport ===
      std::atomic<uint64_t> usbPacketsReceived{0};
      std::atomic<uint64_t> usbPacketsDropped{0};
      std::atomic<uint64_t> usbBytesReceived{0};
      std::atomic<float> usbBandwidthMbps{0.0f};

      // === Timestamp Sync ===
      std::atomic<float> clockDriftPpm{0.0f};
      std::atomic<float> syncConfidence{0.0f};
      std::atomic<int64_t> ptsJitterUs{0};

      // === Buffer State ===
      std::atomic<int> producerQueueDepth{0};
      std::atomic<int> consumerQueueDepth{0};
      std::atomic<uint64_t> bufferOverflows{0};
      std::atomic<uint64_t> consumerStarves{0};

      // === Error Tracking ===
      std::atomic<uint64_t> totalErrors{0};
      CircularBuffer<ErrorEntry, 32> errorHistory;

      // === Session Info ===
      int64_t sessionStartNs{0};
      uint32_t negotiatedWidth{0};
      uint32_t negotiatedHeight{0};
      float negotiatedFps{0.0f};
      FrameFormat negotiatedFormat{FrameFormat::Unknown};

      // === Computed Metrics ===
      float actualFps() const {
          auto elapsed = now() - sessionStartNs;
          return framesDelivered * 1e9f / elapsed;
      }

      float dropRate() const {
          auto total = framesReceived.load();
          return total > 0 ? (float)framesDropped / total : 0.0f;
      }

      float deliveryRate() const {
          return 1.0f - dropRate();
      }
  };

  8.2 Real-Time Dashboard Data

  // Kotlin API for live telemetry
  interface TelemetryListener {
      // Called at configurable interval (default 100ms)
      fun onTelemetryUpdate(snapshot: TelemetrySnapshot)

      // Called immediately on significant events
      fun onFrameDropped(reason: DropReason, frameNumber: Long)
      fun onErrorRecorded(error: ErrorEntry)
      fun onFallbackTriggered(newLevel: Int, reason: String)
  }

  data class TelemetrySnapshot(
      // Performance
      val fps: Float,
      val latencyMs: Float,
      val dropRate: Float,

      // USB health
      val bandwidthMbps: Float,
      val bandwidthUtilization: Float,

      // Timestamps
      val clockDriftPpm: Float,
      val syncConfidence: Float,

      // Buffers
      val bufferUtilization: Float,

      // Session
      val uptime: Duration,
      val framesDelivered: Long,
      val errors: Int,
  )

  ---
  9. Hardware Acceleration Paths

  9.1 MJPEG Decode Options

  class MjpegDecoder {
  public:
      enum class Backend {
          LibjpegTurbo,    // CPU, SIMD-optimized
          MediaCodec,       // Hardware JPEG (if available)
          GPU,              // Custom GPU shader (future)
      };

      // Auto-select best backend for device
      static std::unique_ptr<MjpegDecoder> create(Backend preferred = Backend::Auto);

      // Decode interface
      virtual Result<void> decode(const uint8_t* jpegData, size_t jpegSize,
                                  AHardwareBuffer* outputBuffer) = 0;

      // Direct-to-surface decode (zero intermediate buffer)
      virtual Result<void> decodeToSurface(const uint8_t* jpegData, size_t jpegSize,
                                           ANativeWindow* surface) = 0;
  };

  9.2 H.264/HEVC Pipeline

  class H264Pipeline {
  public:
      struct Config {
          ANativeWindow* outputSurface;
          bool lowLatencyMode = true;
          int maxInputBuffers = 4;
          int maxOutputBuffers = 4;
      };

      Result<void> configure(const Config& config);

      // Called from UVC payload processing
      Result<void> queueNalUnit(const uint8_t* nalData, size_t nalSize,
                                int64_t presentationTimeUs);

      // Frame output notification
      using FrameCallback = std::function<void(int64_t pts, int64_t renderTime)>;
      void setFrameCallback(FrameCallback callback);

  private:
      AMediaCodec* mCodec;
      NalParser mNalParser;      // SPS/PPS extraction, NAL parsing
      std::queue<InputBuffer> mPendingInputs;

      // Async MediaCodec callbacks
      static void onInputAvailable(AMediaCodec*, void*, int32_t index);
      static void onOutputAvailable(AMediaCodec*, void*, int32_t index,
                                     AMediaCodecBufferInfo* info);
  };

  9.3 GPU Color Conversion

  class GpuColorConverter {
  public:
      // Shader-based YUYV → RGBA conversion
      // Input: YUYV data in AHardwareBuffer (usage: GPU_SAMPLED_IMAGE)
      // Output: RGBA in AHardwareBuffer or direct to Surface

      Result<void> convertYuyvToRgba(AHardwareBuffer* input,
                                      AHardwareBuffer* output);

      Result<void> convertYuyvToSurface(AHardwareBuffer* input,
                                         ANativeWindow* surface);

  private:
      EGLDisplay mDisplay;
      EGLContext mContext;
      GLuint mShaderProgram;
      GLuint mYuyvTexture;

      static constexpr char YUYV_TO_RGBA_SHADER[] = R"(
          #version 300 es
          precision mediump float;
          uniform sampler2D yuyvTexture;
          in vec2 texCoord;
          out vec4 fragColor;

          void main() {
              // YUYV unpacking and YUV→RGB conversion
              vec4 yuyv = texture(yuyvTexture, texCoord);
              float y = (texCoord.x * textureSize(yuyvTexture, 0).x) mod 2.0 < 1.0
                        ? yuyv.r : yuyv.b;
              float u = yuyv.g - 0.5;
              float v = yuyv.a - 0.5;

              fragColor = vec4(
                  y + 1.402 * v,
                  y - 0.344 * u - 0.714 * v,
                  y + 1.772 * u,
                  1.0
              );
          }
      )";
  };

  ---
  10. API Design Goals

  10.1 Kotlin/Java API (Application Layer)

  // Discovery
  val manager = UVCCameraManager.getInstance(context)
  manager.setDeviceListener(object : DeviceListener {
      override fun onDeviceAttached(device: UVCDevice) { }
      override fun onDeviceDetached(device: UVCDevice) { }
  })

  // Open camera
  val camera = manager.openCamera(device)

  // Query capabilities
  val formats = camera.supportedFormats
  val controls = camera.controlCapabilities

  // Configure
  camera.setFormat(
      width = 1920,
      height = 1080,
      fps = 30f,
      format = FrameFormat.MJPEG
  )

  // Start streaming
  camera.startPreview(surfaceView.holder.surface)

  // Or receive frames directly
  camera.setFrameCallback { frame ->
      // frame.data: ByteBuffer
      // frame.metadata: FrameMetadata (timestamps, sequence)
  }

  // Controls
  camera.controls.brightness.value = 50
  camera.controls.focusAuto.enabled = true

  // Telemetry
  camera.telemetry.observe { snapshot ->
      fpsTextView.text = "%.1f fps".format(snapshot.fps)
  }

  // Cleanup
  camera.close()

  10.2 C++ API (Native Layer)

  // Modern C++ with RAII
  {
      auto context = UVCContext::create();

      auto devices = context->findDevices();
      auto camera = devices[0]->open();

      // Format negotiation
      auto format = camera->negotiateFormat({
          .width = 1920,
          .height = 1080,
          .fps = 30.0f,
          .preferredFormat = FrameFormat::MJPEG,
      });

      // Stream with callback
      camera->startStream(format, [](const Frame& frame) {
          // frame.data()
          // frame.metadata()
      });

      // Or with Surface
      camera->startPreview(format, nativeWindow);

      // Controls with capability checking
      if (auto brightness = camera->controls().brightness; brightness.isWritable()) {
          brightness.set(50);
      }

      // Automatic cleanup on scope exit
  }

  ---
  11. Testing Vision

  11.1 Test Coverage Goals
  ┌─────────────────────────┬─────────────────┬────────────────────────┐
  │          Layer          │ Target Coverage │       Test Type        │
  ├─────────────────────────┼─────────────────┼────────────────────────┤
  │ libuvc protocol parsing │ 90%             │ Unit tests             │
  ├─────────────────────────┼─────────────────┼────────────────────────┤
  │ Control plane           │ 85%             │ Unit tests             │
  ├─────────────────────────┼─────────────────┼────────────────────────┤
  │ Frame pipeline          │ 80%             │ Unit + integration     │
  ├─────────────────────────┼─────────────────┼────────────────────────┤
  │ Error handling          │ 90%             │ Unit + fault injection │
  ├─────────────────────────┼─────────────────┼────────────────────────┤
  │ JNI bridge              │ 70%             │ Integration            │
  ├─────────────────────────┼─────────────────┼────────────────────────┤
  │ End-to-end              │ N/A             │ Manual + device farm   │
  └─────────────────────────┴─────────────────┴────────────────────────┘
  11.2 Mock Infrastructure

  // Comprehensive camera simulator
  class MockUVCCamera {
  public:
      // Configuration
      void setDescriptors(const DeviceDescriptor& desc);
      void setFormats(const std::vector<FormatDescriptor>& formats);
      void setControls(const std::vector<ControlDescriptor>& controls);

      // Frame injection
      void injectFrame(FrameFormat format, uint32_t width, uint32_t height,
                       const uint8_t* data, size_t size);
      void injectMjpegFrame(uint32_t width, uint32_t height, int quality = 80);
      void injectYuyvFrame(uint32_t width, uint32_t height, Color color);

      // Control simulation
      void setControlValue(uint8_t unit, uint8_t selector, int value);
      void simulateControlError(uint8_t unit, uint8_t selector, UVCError error);

      // Error injection
      void simulateDisconnect();
      void simulateBandwidthExceeded();
      void simulateFrameCorruption(float probability);
      void simulateTimestampJitter(int64_t maxJitterUs);

      // Get libuvc-compatible handle
      uvc_device_handle_t* getHandle();
  };

  ---
  12. Documentation Goals

  12.1 Developer Documentation

  - Getting Started Guide - 5-minute quick start
  - API Reference - Generated from code with examples
  - Architecture Guide - Deep dive into internals
  - Troubleshooting Guide - Common issues and solutions
  - Camera Compatibility Matrix - Tested cameras and quirks

  12.2 Integration Examples

  examples/
  ├── basic-preview/          # Simplest possible preview
  ├── frame-callback/         # Direct frame access
  ├── camera-controls/        # Control manipulation
  ├── multi-camera/           # Multiple simultaneous cameras
  ├── recording/              # Save to file with timestamps
  ├── low-latency/            # Optimized for minimum latency
  ├── extension-units/        # Vendor-specific features
  └── telemetry-dashboard/    # Real-time metrics display

  ---
  13. Success Metrics

  13.1 Performance Targets
  ┌────────────────────────┬─────────┬───────────────────────┐
  │         Metric         │ Target  │      Measurement      │
  ├────────────────────────┼─────────┼───────────────────────┤
  │ Glass-to-glass latency │ < 50ms  │ USB camera → display  │
  ├────────────────────────┼─────────┼───────────────────────┤
  │ Frame drop rate        │ < 0.1%  │ Steady state at 30fps │
  ├────────────────────────┼─────────┼───────────────────────┤
  │ CPU usage (preview)    │ < 10%   │ MJPEG 1080p30         │
  ├────────────────────────┼─────────┼───────────────────────┤
  │ Memory footprint       │ < 50MB  │ Including all buffers │
  ├────────────────────────┼─────────┼───────────────────────┤
  │ Time to first frame    │ < 500ms │ From startPreview()   │
  ├────────────────────────┼─────────┼───────────────────────┤
  │ Hot-plug response      │ < 100ms │ Device detection      │
  └────────────────────────┴─────────┴───────────────────────┘
  13.2 Compatibility Targets
  ┌───────────────────┬────────────────────────────────────────┐
  │     Category      │                 Target                 │
  ├───────────────────┼────────────────────────────────────────┤
  │ Android versions  │ API 26+ (Android 8.0+)                 │
  ├───────────────────┼────────────────────────────────────────┤
  │ Camera compliance │ Any UVC 1.0, 1.1, 1.5 device           │
  ├───────────────────┼────────────────────────────────────────┤
  │ USB modes         │ USB 2.0 High-Speed, USB 3.x SuperSpeed │
  ├───────────────────┼────────────────────────────────────────┤
  │ Architectures     │ arm64-v8a, armeabi-v7a                 │
  └───────────────────┴────────────────────────────────────────┘
  ---
  14. Summary: The Dream Realized

  When complete, ScopeCam's UVC implementation will provide:

  1. Instant Recognition - Plug any UVC camera, it works immediately
  2. Perfect Timestamps - Every frame accurately timestamped to < 1ms
  3. Zero-Copy Display - Hardware-accelerated paths, minimal latency
  4. Full Control - Every camera feature exposed and controllable
  5. Vendor Extensions - Framework for camera-specific features
  6. Graceful Degradation - Always works, quality scales to capability
  7. Complete Observability - Every metric visible, every error diagnosed
  8. Rock-Solid Reliability - Handles disconnects, errors, edge cases
  9. Developer-Friendly - Simple API for common cases, power for advanced
  10. Thoroughly Tested - Confidence in every release

  This is the north star for UVC camera support on Android.

