# INVENTORY-006: Baseline Metrics

**Audit:** AUDIT-001 UVCCamera Codebase Reconnaissance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`
**Tools:** cloc v2.06, lizard

---

## Executive Summary

| Metric | Value | Assessment |
|--------|-------|------------|
| Total Source Files | 712 | Large codebase |
| Total Lines of Code | 224,900 | Significant |
| Core Components LOC | ~114,000 | C/C++/ASM only |
| Average Cyclomatic Complexity | 4.5 | Healthy average |
| High Complexity Functions (CC>15) | 148 | ~3% of functions |
| Technical Debt Markers | 618 | Moderate |

---

## Code Volume (cloc Analysis)

### Language Distribution

| Language | Files | Blank | Comment | Code | % of Code |
|----------|-------|-------|---------|------|-----------|
| C | 177 | 14,119 | 22,756 | 70,303 | 31.3% |
| Bourne Shell | 15 | 4,013 | 4,714 | 25,748 | 11.4% |
| Assembly | 65 | 4,913 | 4,733 | 25,486 | 11.3% |
| C/C++ Header | 150 | 4,841 | 11,967 | 22,414 | 10.0% |
| C++ | 64 | 3,706 | 3,496 | 20,737 | 9.2% |
| HTML | 60 | 155 | 1,076 | 12,032 | 5.3% |
| m4 | 4 | 1,108 | 105 | 10,375 | 4.6% |
| MSBuild script | 11 | 0 | 0 | 7,976 | 3.5% |
| Text | 21 | 964 | 0 | 7,287 | 3.2% |
| Other | 145 | 6,710 | 2,540 | 22,542 | 10.0% |
| **TOTAL** | **712** | **36,529** | **51,387** | **224,900** | **100%** |

### Native Code Focus (C/C++/ASM Only)

| Language | Files | Code Lines | % |
|----------|-------|------------|---|
| C | 177 | 70,303 | 62% |
| Assembly | 65 | 25,486 | 22% |
| C++ | 64 | 20,737 | 18% |
| **Total Native** | **306** | **116,526** | 100% |

### Component Breakdown

| Component | Files | Code Lines | Purpose |
|-----------|-------|------------|---------|
| **UVCCamera** | 52 | 12,456 | Core library |
| **libjpeg-turbo** | ~200 | ~85,000 | JPEG codec |
| **libusb** | ~50 | ~15,000 | USB transport |
| **libuvc** | ~25 | ~8,000 | UVC protocol |
| **rapidjson** | ~100 | ~15,000 | JSON (tests) |
| **test** | ~20 | ~2,000 | Unit tests |

### UVCCamera Core Details

| Language | Files | Blank | Comment | Code |
|----------|-------|-------|---------|------|
| C++ | 25 | 1,949 | 2,386 | 10,619 |
| C/C++ Header | 26 | 457 | 1,150 | 1,798 |
| make | 1 | 9 | 30 | 39 |
| **Total** | **52** | **2,415** | **3,566** | **12,456** |

---

## Complexity Analysis (lizard)

### Overall Metrics

| Metric | Value |
|--------|-------|
| Total Functions Analyzed | 4,786 |
| Average NLOC per Function | 18.2 |
| Average Cyclomatic Complexity | 4.5 |
| Average Token Count | 126.1 |
| Functions with Warnings (CC>15) | 148 |
| Warning Ratio | 3% |

### Complexity Distribution

| CC Range | Category | Typical Count |
|----------|----------|---------------|
| 1-5 | Low (simple) | ~80% |
| 6-10 | Moderate | ~14% |
| 11-15 | High | ~3% |
| 16-20 | Very High | ~2% |
| 21+ | Extreme | ~1% |

### Highest Complexity Functions (CC > 25)

| Function | File | CC | NLOC | Component |
|----------|------|----|------|-----------|
| `decompress_smooth_data` | jdcoefct.c | 55 | 176 | libjpeg-turbo |
| `parse_switches` | djpeg.c | 67 | 157 | libjpeg-turbo |
| `parse_switches` | cjpeg.c | 71 | 168 | libjpeg-turbo |
| `main` | djpeg.c | 49 | 175 | libjpeg-turbo |
| `bufSizeTest` | tjunittest.c | 32 | 83 | libjpeg-turbo |
| `start_pass` | jdarith.c | 36 | 81 | libjpeg-turbo |
| `update_box` | jquant2.c | 35 | 93 | libjpeg-turbo |
| `Java_org_libjpegturbo_turbojpeg_TJTransformer_transform` | turbojpeg-jni.c | 29 | 112 | libjpeg-turbo |

**Note:** Most high-complexity functions are in libjpeg-turbo (third-party dependency), not in UVCCamera core.

### UVCCamera Core Complexity

The core UVCCamera component shows lower complexity than third-party code:

| File | Highest Function CC | Notes |
|------|---------------------|-------|
| UVCPreview.cpp | ~15 | Preview thread logic |
| UVCCamera.cpp | ~12 | Device management |
| FrameBufferRing.cpp | ~8 | Ring buffer ops |
| HandleManager.cpp | ~5 | Handle slot logic |

---

## Technical Debt Markers

### Summary by Type

| Marker | Count | Priority |
|--------|-------|----------|
| `BUG` | 254 | High - Active bugs |
| `XXX` | 253 | Medium - Attention needed |
| `FIXME` | 64 | Medium - Known issues |
| `TODO` | 47 | Low - Future work |
| `HACK` | 1 | Low - Workarounds |
| **Total** | **618** | - |

### Distribution by Component

| Component | Estimated Markers | Notes |
|-----------|-------------------|-------|
| libjpeg-turbo | ~400 | Most markers |
| libusb | ~100 | Legacy code |
| libuvc | ~50 | Forked code |
| UVCCamera | ~50 | Core library |
| rapidjson | ~20 | Tests |

### High-Priority Technical Debt

The `BUG` and `XXX` markers (507 total) warrant review for:
- Known defects awaiting fixes
- Code sections needing attention
- Compatibility issues
- Performance concerns

---

## Memory Safety Indicators

### malloc() Usage by File (Top 10)

| File | Count | Component | Risk Level |
|------|-------|-----------|------------|
| turbojpeg.c | 28 | libjpeg | Medium |
| descriptor_original.c | 13 | libusb | Low (legacy) |
| descriptor.c | 11 | libusb | Medium |
| tjbench.c | 10 | libjpeg | Low (test) |
| tjunittest.c | 6 | libjpeg | Low (test) |
| stream.c | 4 | libuvc | Medium |
| device.c | 4 | libuvc | Medium |

### free() Usage by File (Top 10)

| File | Count | Component | Balance Check |
|------|-------|-----------|---------------|
| windows_usb.c | 28 | libusb | N/A (not built) |
| turbojpeg.c | 28 | libjpeg | ✅ Balanced |
| descriptor.c | 19 | libusb | ✅ ~Balanced |
| device.c | 18 | libuvc | ✅ ~Balanced |
| android_usbfs.c | 14 | libusb | Review needed |
| core.c | 13 | libusb | ✅ ~Balanced |

### memcpy() Usage by File (Top 10)

| File | Count | Component | Buffer Overflow Risk |
|------|-------|-----------|---------------------|
| windows_usb.c | 20 | libusb | N/A (not built) |
| **UVCPreview.cpp** | 12 | UVCCamera | **Review** |
| PreviewPipeline.cpp | 9 | UVCCamera | Review |
| descriptor.c | 9 | libusb | Low |
| **FrameBufferRing.cpp** | 5 | UVCCamera | **Review** |

### Memory Safety Assessment

| Concern | Status | Recommendation |
|---------|--------|----------------|
| UVCPreview.cpp memcpy | Review needed | Verify bounds checking |
| FrameBufferRing.cpp | Review needed | Check buffer sizes |
| HandleManager | Low risk | Uses RAII, slot-based |
| libuvc allocations | Moderate | Third-party code |

---

## Comment Ratio Analysis

### By Language

| Language | Code Lines | Comment Lines | Ratio |
|----------|------------|---------------|-------|
| C | 70,303 | 22,756 | 32% |
| C++ | 20,737 | 3,496 | 17% |
| Headers | 22,414 | 11,967 | 53% |

### Assessment
- **C code:** Well commented (32%)
- **C++ code:** Moderate commenting (17%)
- **Headers:** Extensively documented (53%)

---

## Code Quality Indicators

### Positive Indicators

| Indicator | Status | Evidence |
|-----------|--------|----------|
| RAII patterns | ✅ Good | HandleManager, modern C++ |
| Const correctness | ✅ Good | OutputMode::toString() |
| Header organization | ✅ Good | Public/internal separation |
| Error handling | ✅ Good | UVC_RETURN_ON_ERROR macro |
| Logging | ✅ Good | Comprehensive LOGD/LOGI |

### Areas for Improvement

| Area | Current | Target | Priority |
|------|---------|--------|----------|
| Test coverage | ~2,000 LOC | Higher | Medium |
| C++ modernization | Mixed C/C++ | C++20 | High |
| Memory safety | Manual | RAII everywhere | High |
| Threading | pthread | std::jthread | Medium |

---

## File Size Distribution

### Largest Files (by LOC)

| Rank | File | Lines | Component |
|------|------|-------|-----------|
| 1 | UVCPreview.cpp | 3,006 | UVCCamera |
| 2 | UVCCamera.cpp | 2,894 | UVCCamera |
| 3 | turbojpeg.c | ~2,500 | libjpeg-turbo |
| 4 | jdcoefct.c | ~2,000 | libjpeg-turbo |
| 5 | windows_usb.c | ~1,800 | libusb (N/A) |

### Recommendation
- **UVCPreview.cpp** and **UVCCamera.cpp** are candidates for refactoring/splitting

---

## Baseline Metrics Summary

### Key Numbers

```
┌─────────────────────────────────────────────────┐
│             CODEBASE METRICS                    │
├─────────────────────────────────────────────────┤
│  Total Files:              712                  │
│  Total LOC:                224,900              │
│  Native Code LOC:          116,526              │
│  UVCCamera Core LOC:       12,456               │
├─────────────────────────────────────────────────┤
│  Total Functions:          4,786                │
│  Avg Cyclomatic Complexity: 4.5                 │
│  High Complexity (CC>15):  148 (3%)             │
├─────────────────────────────────────────────────┤
│  Technical Debt Markers:   618                  │
│  malloc() calls:           ~150                 │
│  free() calls:             ~200                 │
│  memcpy() calls:           ~100                 │
└─────────────────────────────────────────────────┘
```

---

## Raw Data References

| File | Description |
|------|-------------|
| `raw/cloc-summary.csv` | Full cloc output |
| `raw/complexity.csv` | Lizard complexity per function |
| `raw/technical-debt-markers.txt` | All TODO/FIXME/etc. locations |

---

## Platform Target Metrics

### Build Target Requirements

| Requirement | Current | Target | Notes |
|-------------|---------|--------|-------|
| Android API | 21+ | 36 (Android 16) | See Appendix D |
| NDK Version | r21 | r28+ | C++20 support |
| Kernel | 4.x | ACK 6.1+ | V4L2 data_offset |
| C++ Standard | C++14 | C++23 | jthread, coroutines |

### Platform-Specific Concerns

| Concern | Status | Action | Reference |
|---------|--------|--------|-----------|
| V4L2 data_offset | Not used | Future-proof for NV12 | Appendix C.1 |
| UVC quirk handling | Partial | Document in codebase | Appendix C.2 |
| CVE-2024-58002 | Mitigated (HandleManager) | Monitor kernel patches | Appendix C.3 |
| Android 16 USB protection | Partial | Update hardReset | Appendix D.2 |
| Foreground service | Not in scope | Kotlin layer | Appendix D.2 |

### AHardwareBuffer Migration Status

| Path | Status | Performance | Notes |
|------|--------|-------------|-------|
| Legacy ANativeWindow | ✅ Working | Baseline | To be deprecated |
| Hybrid AHardwareBuffer | ✅ Working | +30% FPS | Recommended |
| Full AHardwareBuffer | 🔄 In progress | Target | CONCURRENCY-004 |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| INVENTORY-001 | Directory structure context |
| INVENTORY-002 | Source file counts |
| INVENTORY-003 | Header analysis |
| INVENTORY-004 | Build configuration |
| INVENTORY-005 | Dependency graph |
| **AUDIT-001-appendix-background.md** | V4L2/UVC/Android context |
| SAFETY-001 through SAFETY-009 | Memory safety findings |
| CONCURRENCY-001 through CONCURRENCY-010 | Threading analysis |

---

*End of INVENTORY-006*
