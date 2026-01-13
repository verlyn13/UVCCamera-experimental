# FEASIBILITY-008: Testing Infrastructure

**Status:** Complete
**Date:** 2026-01-11
**Author:** Claude
**Depends On:** None (standalone infrastructure assessment)

---

## Executive Summary

The testing infrastructure has a **solid foundation** with host-based native tests using Google Test, comprehensive mocks for Android APIs, and CI/CD via GitHub Actions. Major gaps exist in **Android instrumented tests**, **integration tests**, and **coverage reporting**. The mock infrastructure is particularly well-designed, enabling extensive unit testing without hardware.

**Key Finding:** Native unit testing is well-established (~600 LOC of tests). Android instrumentation testing is absent.

**Recommendation:** **GO** - Expand testing incrementally, starting with CI coverage reporting and gradually adding instrumented tests.

---

## 1. Current State Analysis

### 1.1 Test Inventory

| Category | Status | Location |
|----------|--------|----------|
| Native unit tests | **Implemented** | `jni/test/tests/` |
| Android mocks | **Implemented** | `jni/test/mocks/` |
| CMake test build | **Implemented** | `jni/test/CMakeLists.txt` |
| CI pipeline | **Implemented** | `.github/workflows/ci.yaml` |
| Host test execution | **Implemented** | Ubuntu + macOS |
| Android instrumented tests | **Missing** | N/A |
| Integration tests | **Missing** | N/A |
| Coverage reporting | **Missing** | N/A |

### 1.2 Native Test Files

| File | LOC | Coverage Area |
|------|-----|---------------|
| `FrameBufferRingTest.cpp` | 372 | Triple-buffer, MAILBOX policy, telemetry |
| `StreamTelemetryTest.cpp` | 229 | Atomic ops, EMA calculations, error history |
| `ContractTest.cpp` | 68 | Constant verification between layers |
| **Total** | **~669** | |

### 1.3 Mock Infrastructure

**AndroidApiMocks.h/cpp** - Comprehensive mock for:
- `AHardwareBuffer_*` API (allocate, release, lock, unlock)
- `poll()` / `close()` system calls
- `clock_gettime()` for time-based tests
- Logging stubs (LOGE, LOGW, etc.)

**Mock Control Interface:**
```cpp
namespace MockControl {
    void setAllocateFailAfter(int successCount);
    void setLockReturnStride(int32_t stride);
    void setUnlockReturnFence(int32_t fenceFd);
    void setPollReturnValue(int value);
    void setCurrentTimeNs(int64_t timeNs);
    void reset();
    // ... inspection methods
}
```

**Strengths:**
- Clean separation via `UVCCAMERA_TESTING` compile flag
- Controllable failures for error path testing
- Call count tracking for verification
- Time control for deterministic tests

### 1.4 CI/CD Configuration

**GitHub Actions (`.github/workflows/ci.yaml`):**

```yaml
jobs:
  native-tests:
    strategy:
      matrix:
        os: [ubuntu-24.04, macos-latest]
    steps:
      - cmake -B build
      - cmake --build build
      - ctest --output-on-failure

  package:
    steps:
      - ./gradlew assembleRelease publishToMavenLocal
      - flutter build apk
      - # Docs generation
```

**Current CI covers:**
- Native tests on Ubuntu and macOS
- Android release build
- Flutter plugin build
- Documentation build

**Missing from CI:**
- Coverage reporting
- Android instrumented tests
- Memory sanitizers (ASan/TSan)
- Performance benchmarks

### 1.5 CMake Test Build

```cmake
cmake_minimum_required(VERSION 3.22)
project(uvccamera-native-tests)

enable_testing()

# Google Test via FetchContent
FetchContent_Declare(googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG v1.14.0
)

add_executable(native_tests
    ${PRODUCTION_SRC}/FrameBufferRing.cpp
    tests/ContractTest.cpp
    tests/StreamTelemetryTest.cpp
    tests/FrameBufferRingTest.cpp
    mocks/AndroidApiMocks.cpp
)

target_link_libraries(native_tests GTest::gtest_main GTest::gmock)
gtest_discover_tests(native_tests)
```

**Good practices:**
- Modern CMake (3.22)
- FetchContent for dependencies
- Test discovery for CTest integration

---

## 2. Gap Analysis

### 2.1 Missing Test Categories

| Category | Priority | Effort | Value |
|----------|----------|--------|-------|
| Coverage reporting | **HIGH** | Low | Visibility into test coverage |
| Memory sanitizers | **HIGH** | Low | Catch memory bugs |
| UVCPreview tests | **HIGH** | Medium | Core component untested |
| libuvc unit tests | **MEDIUM** | Medium | Protocol layer |
| Android instrumented | **MEDIUM** | High | End-to-end validation |
| Performance benchmarks | **LOW** | Medium | Regression detection |

### 2.2 Untested Components

| Component | LOC | Test Coverage | Risk |
|-----------|-----|---------------|------|
| `FrameBufferRing.cpp` | ~500 | **Tested** | Low |
| `StreamTelemetry.h` | ~300 | **Tested** | Low |
| `UVCPreview.cpp` | ~3000 | **Untested** | HIGH |
| `UVCCamera.cpp` | ~800 | **Untested** | HIGH |
| `libuvc/stream.c` | ~2000 | **Untested** | HIGH |
| `libuvc/ctrl.c` | ~1700 | **Untested** | MEDIUM |
| `libusb/*` | ~3000 | **Untested** | MEDIUM |

### 2.3 Coverage Gap Estimate

**Current estimated coverage:**
- `FrameBufferRing`: ~80%
- `StreamTelemetry`: ~70%
- `UVCPreview`: ~0%
- `libuvc`: ~0%
- **Overall**: ~5-10%

---

## 3. Test Architecture Recommendations

### 3.1 Proposed Test Pyramid

```
              ┌─────────────────┐
              │   E2E / Manual  │  <- Real camera tests
              │    (Device)     │
              └────────┬────────┘
                      │
         ┌────────────┴────────────┐
         │   Integration Tests     │  <- Android instrumented
         │   (Camera simulator)    │
         └────────────┬────────────┘
                      │
    ┌─────────────────┴─────────────────┐
    │         Component Tests           │  <- Host-based with mocks
    │   (UVCPreview, UVCCamera, etc.)   │
    └─────────────────┬─────────────────┘
                      │
┌─────────────────────┴─────────────────────┐
│              Unit Tests                    │  <- Current focus
│   (FrameBufferRing, StreamTelemetry)      │
└───────────────────────────────────────────┘
```

### 3.2 Test Categories Detail

#### 3.2.1 Unit Tests (Expand)

**Target components:**
- `Parameters.cpp` - Configuration handling
- `HandleManager.cpp` - Resource management
- `libuvc/ctrl.c` - Control request parsing
- `libuvc/device.c` - Descriptor parsing

**Mock requirements:**
- None additional (pure logic tests)

#### 3.2.2 Component Tests (New)

**Target components:**
- `UVCPreview.cpp` - Frame processing pipeline
- `UVCCamera.cpp` - Camera lifecycle
- `libuvc/stream.c` - Streaming state machine

**Mock requirements:**
- Mock UVC device (returning synthetic frames)
- Mock Surface/ANativeWindow
- Mock JNI callbacks

**Example test structure:**
```cpp
class UVCPreviewTest : public ::testing::Test {
protected:
    MockUVCDevice mockDevice;
    MockSurface mockSurface;
    UVCPreview preview;

    void SetUp() override {
        mockDevice.setResolution(1920, 1080);
        mockDevice.setFormat(MJPEG);
        preview.setPreviewDisplay(&mockSurface);
    }
};

TEST_F(UVCPreviewTest, FrameCallbackReceivesConvertedFrame) {
    std::vector<uint8_t> capturedFrame;
    preview.setFrameCallback([&](const void* data, size_t len) {
        capturedFrame.assign((uint8_t*)data, (uint8_t*)data + len);
    });

    mockDevice.injectFrame(testMjpegFrame, sizeof(testMjpegFrame));

    EXPECT_FALSE(capturedFrame.empty());
    EXPECT_EQ(capturedFrame.size(), 1920 * 1080 * 4);  // RGBA
}
```

#### 3.2.3 Integration Tests (New)

**Target scenarios:**
- USB permission flow
- Camera discovery and enumeration
- Format negotiation
- Preview start/stop lifecycle
- Error recovery

**Requirements:**
- Android emulator or device
- Mock USB device (software or dedicated hardware)
- Test harness APK

#### 3.2.4 E2E Tests (Manual/Semi-automated)

**Test matrix:**
- Multiple camera models
- Multiple Android versions
- Multiple device types
- USB 2.0 vs USB 3.0

---

## 4. Implementation Recommendations

### 4.1 Phase 1: Quick Wins (1-2 days)

#### 4.1.1 Add Coverage Reporting

**CMakeLists.txt addition:**
```cmake
option(COVERAGE "Enable coverage reporting" OFF)

if(COVERAGE)
    target_compile_options(native_tests PRIVATE --coverage)
    target_link_options(native_tests PRIVATE --coverage)
endif()
```

**CI addition:**
```yaml
- name: Build with coverage
  run: |
    cmake -B build -DCOVERAGE=ON
    cmake --build build
    ctest --test-dir build

- name: Generate coverage report
  run: |
    lcov --capture --directory . --output-file coverage.info
    lcov --remove coverage.info '/usr/*' '*/googletest/*' --output-file coverage.info

- name: Upload to Codecov
  uses: codecov/codecov-action@v4
  with:
    files: coverage.info
```

#### 4.1.2 Add Memory Sanitizers

**CI addition:**
```yaml
- name: Build with ASan
  run: |
    cmake -B build-asan -DCMAKE_CXX_FLAGS="-fsanitize=address -fno-omit-frame-pointer"
    cmake --build build-asan
    ctest --test-dir build-asan

- name: Build with TSan
  run: |
    cmake -B build-tsan -DCMAKE_CXX_FLAGS="-fsanitize=thread"
    cmake --build build-tsan
    ctest --test-dir build-tsan
```

### 4.2 Phase 2: Expand Unit Tests (3-5 days)

#### 4.2.1 Add libuvc Tests

**New test file: `libuvc/DescriptorParsingTest.cpp`**

```cpp
TEST(DescriptorParsingTest, ParsesUncompressedFormatDescriptor) {
    uint8_t descriptor[] = { /* VS_FORMAT_UNCOMPRESSED */ };
    uvc_format_desc_t format;

    int result = uvc_parse_vs_format_uncompressed(nullptr, descriptor, sizeof(descriptor));

    EXPECT_EQ(result, UVC_SUCCESS);
    // Verify parsed fields
}

TEST(DescriptorParsingTest, RejectsInvalidDescriptor) {
    uint8_t badDescriptor[] = { /* malformed */ };

    int result = uvc_parse_vs_format_uncompressed(nullptr, badDescriptor, sizeof(badDescriptor));

    EXPECT_NE(result, UVC_SUCCESS);
}
```

#### 4.2.2 Add Control Parsing Tests

**New test file: `libuvc/ControlRequestTest.cpp`**

```cpp
TEST(ControlRequestTest, ParsesGetCurResponse) {
    uint8_t response[] = { /* GET_CUR response */ };

    int16_t value;
    int result = uvc_get_brightness(mockDevh, &value, UVC_GET_CUR);

    EXPECT_EQ(result, UVC_SUCCESS);
    EXPECT_EQ(value, expectedValue);
}
```

### 4.3 Phase 3: Component Tests (5-7 days)

#### 4.3.1 Mock UVC Device

**New file: `mocks/MockUVCDevice.h`**

```cpp
class MockUVCDevice {
public:
    void setResolution(uint32_t width, uint32_t height);
    void setFormat(enum uvc_frame_format format);
    void setFrameRate(uint32_t fps);

    // Inject synthetic frames
    void injectFrame(const uint8_t* data, size_t len);
    void injectMjpegFrame(uint32_t width, uint32_t height);
    void injectYuyvFrame(uint32_t width, uint32_t height);

    // Get libuvc handle for production code
    uvc_device_handle_t* getHandle();

private:
    // Internal state
    uvc_device_handle_t mockHandle;
    std::queue<std::vector<uint8_t>> frameQueue;
};
```

#### 4.3.2 UVCPreview Tests

**New test file: `tests/UVCPreviewTest.cpp`**

```cpp
class UVCPreviewTest : public ::testing::Test {
protected:
    MockUVCDevice mockDevice;
    MockANativeWindow mockWindow;
    UVCPreview* preview;

    void SetUp() override {
        MockControl::reset();
        preview = new UVCPreview(mockDevice.getHandle());
    }

    void TearDown() override {
        delete preview;
        MockControl::reset();
    }
};

TEST_F(UVCPreviewTest, SetPreviewSizeNegotiatesWithDevice) {
    int result = preview->setPreviewSize(1920, 1080, 30, 30, PREVIEW_MODE_AUTO);

    EXPECT_EQ(result, 0);
    EXPECT_EQ(preview->getFrameWidth(), 1920);
    EXPECT_EQ(preview->getFrameHeight(), 1080);
}

TEST_F(UVCPreviewTest, StartPreviewStartsStreaming) {
    preview->setPreviewDisplay(&mockWindow);
    int result = preview->startPreview();

    EXPECT_EQ(result, 0);
    EXPECT_TRUE(preview->isRunning());
}

TEST_F(UVCPreviewTest, StopPreviewIsIdempotent) {
    // Should not crash even if not started
    int result = preview->stopPreview();
    EXPECT_EQ(result, 0);
}
```

### 4.4 Phase 4: Android Instrumented Tests (5-10 days)

#### 4.4.1 Test Project Setup

**New directory: `lib/src/androidTest/java/org/uvccamera/lib/`**

```java
@RunWith(AndroidJUnit4.class)
public class UVCCameraIntegrationTest {

    @Rule
    public ActivityScenarioRule<TestActivity> activityRule =
            new ActivityScenarioRule<>(TestActivity.class);

    @Test
    public void cameraManagerInitializes() {
        // Test basic initialization without USB permission
        activityRule.getScenario().onActivity(activity -> {
            UVCCameraManager manager = new UVCCameraManager(activity);
            assertNotNull(manager);
        });
    }

    @Test
    @RequiresDevice  // Skip on emulator
    public void cameraEnumerationWorks() {
        // Requires physical USB camera
        // ...
    }
}
```

#### 4.4.2 CI Integration

```yaml
instrumented-tests:
  runs-on: macos-latest  # Required for hardware acceleration

  steps:
    - uses: actions/checkout@v4

    - name: Setup Android SDK
      uses: android-actions/setup-android@v3

    - name: Run Android emulator
      uses: reactivecircus/android-emulator-runner@v2
      with:
        api-level: 29
        arch: x86_64
        script: ./gradlew connectedCheck
```

---

## 5. Effort Estimation

| Phase | Tasks | Effort |
|-------|-------|--------|
| **Phase 1** | Coverage + Sanitizers | 1-2 days |
| **Phase 2** | Expand unit tests | 3-5 days |
| **Phase 3** | Component tests + mocks | 5-7 days |
| **Phase 4** | Android instrumented | 5-10 days |
| **Total** | | **14-24 days** |

---

## 6. Risk Assessment

### 6.1 Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Mock divergence from real API | MEDIUM | MEDIUM | Regular API validation |
| Flaky CI tests | MEDIUM | LOW | Retry logic, test isolation |
| Emulator limitations | HIGH | MEDIUM | Device farm for real tests |
| Coverage gaps in native code | MEDIUM | MEDIUM | Incremental coverage goals |

### 6.2 Maintenance Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Test rot | MEDIUM | HIGH | CI enforcement |
| Mock maintenance burden | MEDIUM | MEDIUM | Minimize mock scope |
| Slow CI pipeline | LOW | MEDIUM | Parallelization |

---

## 7. Metrics and Goals

### 7.1 Coverage Targets

| Milestone | Target | Timeline |
|-----------|--------|----------|
| **M1** | 20% overall | Phase 1 complete |
| **M2** | 40% overall | Phase 2 complete |
| **M3** | 60% overall | Phase 3 complete |
| **M4** | 70%+ overall | Phase 4 complete |

### 7.2 Quality Gates

| Gate | Criteria |
|------|----------|
| **PR Merge** | All tests pass, no coverage regression |
| **Release** | 60%+ coverage, no critical bugs |
| **Major Version** | 70%+ coverage, E2E validation |

---

## 8. Recommendation

### 8.1 Decision: **GO**

**Rationale:**
1. Solid foundation already exists
2. Critical components (UVCPreview, libuvc) are untested
3. CI pipeline is established but incomplete
4. Incremental improvement is low risk

### 8.2 Prioritized Roadmap

1. **Immediate (This Week):**
   - Add coverage reporting to CI
   - Add ASan to CI
   - Document test running instructions

2. **Short-term (2-3 weeks):**
   - Expand unit tests for libuvc
   - Add UVCPreview component tests
   - Reach 40% coverage

3. **Medium-term (1-2 months):**
   - Android instrumented tests
   - Device lab integration (Firebase Test Lab)
   - Reach 60% coverage

4. **Long-term:**
   - Performance regression tests
   - Camera compatibility matrix
   - 70%+ coverage maintenance

### 8.3 Success Criteria

- Coverage badge in README
- All CI checks required for merge
- No regressions in existing functionality
- Documented test categories and running instructions

---

## Appendix A: Test Running Instructions

### A.1 Native Tests (Host)

```bash
cd lib/src/main/jni/test
cmake -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

### A.2 Native Tests with Coverage

```bash
cmake -B build -DCOVERAGE=ON
cmake --build build
ctest --test-dir build
lcov --capture --directory . --output-file coverage.info
genhtml coverage.info --output-directory coverage-report
open coverage-report/index.html
```

### A.3 Native Tests with ASan

```bash
cmake -B build -DCMAKE_CXX_FLAGS="-fsanitize=address"
cmake --build build
ctest --test-dir build
```

### A.4 Android Tests (Future)

```bash
./gradlew :lib:connectedCheck
```

---

## Appendix B: Mock Expansion Guide

### B.1 Adding New Android API Mocks

1. Add type definitions to `AndroidApiMocks.h`
2. Add mock implementation to `AndroidApiMocks.cpp`
3. Add control interface to `MockControl` namespace
4. Add `#define` redirect for production code

### B.2 Adding New libuvc Mocks

Create separate mock file for complex components:

```cpp
// mocks/MockUVCDevice.h
class MockUVCDevice {
public:
    // Configuration
    void setDescriptors(const uvc_device_descriptor_t& desc);
    void setStreamingFormats(const std::vector<uvc_format_desc_t>& formats);

    // Frame injection
    void injectFrame(const uvc_frame_t& frame);

    // Verification
    int getStartStreamingCallCount() const;
    int getStopStreamingCallCount() const;
};
```

---

## Appendix C: CI Workflow Enhancement

### C.1 Complete Test Job

```yaml
test-matrix:
  strategy:
    matrix:
      os: [ubuntu-24.04, macos-latest]
      build_type: [Debug, Release]
      sanitizer: [none, asan, tsan]
      exclude:
        - build_type: Release
          sanitizer: tsan  # TSan only useful in Debug

  runs-on: ${{ matrix.os }}

  steps:
    - uses: actions/checkout@v4

    - name: Configure
      run: |
        cmake -B build \
          -DCMAKE_BUILD_TYPE=${{ matrix.build_type }} \
          ${{ matrix.sanitizer != 'none' && format('-DCMAKE_CXX_FLAGS=-fsanitize={0}', matrix.sanitizer) || '' }}

    - name: Build
      run: cmake --build build

    - name: Test
      run: ctest --test-dir build --output-on-failure

    - name: Coverage
      if: matrix.build_type == 'Debug' && matrix.sanitizer == 'none'
      run: |
        lcov --capture --directory . --output-file coverage.info
        codecov upload coverage.info
```

---

*End of FEASIBILITY-008*
