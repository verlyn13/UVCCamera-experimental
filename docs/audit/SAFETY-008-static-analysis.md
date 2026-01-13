# SAFETY-008: Static Analysis Configuration

**Audit:** AUDIT-002 Memory Safety Audit
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Tool Summary

| Tool | Version | Status | Purpose |
|------|---------|--------|---------|
| **cppcheck** | 2.19.0 | Configured | Memory safety, undefined behavior |
| **clang-tidy** | NDK r28 | Recommended | Modern C++ checks |
| **AddressSanitizer** | NDK | Recommended | Runtime detection |
| **semgrep** | N/A | Optional | Pattern-based rules |

---

## Cppcheck Configuration

### Configuration Files

**Location:** `docs/audit/SAFETY-008-static-analysis-config/`

| File | Purpose |
|------|---------|
| `cppcheck.cfg` | Project configuration |
| `cppcheck-uvccamera.xml` | XML report output |

### Run Commands

```bash
# Full analysis with XML output
cppcheck --enable=all --suppress=missingIncludeSystem --xml --xml-version=2 \
    lib/src/main/jni/UVCCamera/*.cpp lib/src/main/jni/UVCCamera/*.h \
    2> docs/audit/SAFETY-008-static-analysis-config/report.xml

# Human-readable output
cppcheck --enable=warning,performance,portability \
    --suppress=missingIncludeSystem \
    --template='{file}:{line}: {severity}: {message} [{id}]' \
    lib/src/main/jni/UVCCamera/

# CI integration (error exit on issues)
cppcheck --enable=warning --error-exitcode=1 \
    lib/src/main/jni/UVCCamera/
```

---

## Static Analysis Findings

### Critical Issues

| File | Line | ID | Severity | Message |
|------|------|-----|----------|---------|
| FrameBufferJNI.cpp | 129 | deallocuse | error | Dereferencing 'ring' after it is deallocated |
| FrameBufferJNI.cpp | 130 | doubleFree | error | Memory pointed to by 'ring' is freed twice |

### Warnings (Actionable)

| File | Line | ID | Message |
|------|------|----|---------|
| FrameBufferRing.h | 78 | noCopyConstructor | Struct 'PendingFrame' does not have a copy constructor |
| FrameBufferRing.h | 78 | noOperatorEq | Struct 'PendingFrame' does not have operator= |
| FrameBufferRing.cpp | 109 | uninitMemberVar | Member variable 'mMetadata' not initialized |
| FrameBufferRing.cpp | 109 | uninitMemberVar | Member variable 'mTelemetry' not initialized |

### Analysis Notes

**Syntax Error in objectarray.h:**
Line 67 has a detected syntax error. This may be a parsing issue with cppcheck or an actual problem in the header.

---

## Issue Resolution Guide

### SA-001: deallocuse / doubleFree in FrameBufferJNI.cpp

**Location:** `FrameBufferJNI.cpp:129-130`
**Analysis Required:** Review the allocation pattern around this code. The static analyzer detected a potential use-after-free and double-free scenario.

**Recommendation:** Verify the ownership model and ensure proper RAII pattern is used.

---

### SA-002: Missing Rule of Five in PendingFrame

**Location:** `FrameBufferRing.h:78`
**Issue:** Struct with dynamic memory (raw pointer `void* data`) lacks copy constructor and copy assignment operator.

**Current Code:**
```cpp
struct PendingFrame {
    void* data{nullptr};
    // ...
    ~PendingFrame() {
        if (data) {
            free(data);
            data = nullptr;
        }
    }
};
```

**Problem:** Default copy semantics will cause double-free.

**Fix (2026 Style):**
```cpp
struct PendingFrame {
    std::unique_ptr<std::byte[]> data;
    size_t dataBytes{0};
    size_t bufferCapacity{0};
    // ...

    // Move-only semantics (no raw pointer management needed)
    PendingFrame() = default;
    PendingFrame(PendingFrame&&) = default;
    PendingFrame& operator=(PendingFrame&&) = default;

    // Delete copy operations
    PendingFrame(const PendingFrame&) = delete;
    PendingFrame& operator=(const PendingFrame&) = delete;
};
```

---

### SA-003: Uninitialized Members in FrameBufferRing

**Location:** `FrameBufferRing.cpp:109`
**Issue:** Array members and padding not explicitly initialized.

**Fix:**
```cpp
FrameBufferRing::FrameBufferRing()
    : mBuffers{}           // Zero-initialize array
    , mMetadata{}          // Default-initialize array
    , mPendingFrames{}     // Default-initialize array
    , _paddingWrite{}      // Zero-initialize padding
    , _paddingRead{}       // Zero-initialize padding
    , mTelemetry{}         // Default-initialize telemetry
{
    // Additional initialization...
}
```

---

## clang-tidy Configuration (Recommended)

### Configuration File (.clang-tidy)

```yaml
---
Checks: >
  bugprone-*,
  cert-*,
  clang-analyzer-*,
  cppcoreguidelines-*,
  misc-*,
  modernize-*,
  performance-*,
  portability-*,
  readability-*,
  -modernize-use-trailing-return-type,
  -cppcoreguidelines-avoid-magic-numbers,
  -readability-magic-numbers,
  -cppcoreguidelines-pro-type-reinterpret-cast,
  -cppcoreguidelines-pro-type-union-access,
  -cppcoreguidelines-pro-bounds-pointer-arithmetic

WarningsAsErrors: >
  bugprone-use-after-move,
  bugprone-double-free,
  cert-err33-c,
  clang-analyzer-*

CheckOptions:
  - key: bugprone-assert-side-effect.AssertMacros
    value: 'assert,LOGE'
  - key: cppcoreguidelines-special-member-functions.AllowSoleDefaultDtor
    value: true
  - key: modernize-use-nullptr.NullMacros
    value: 'NULL'
  - key: readability-function-size.LineThreshold
    value: 150

FormatStyle: file
HeaderFilterRegex: 'UVCCamera/.*\.h$'
```

### Run Commands

```bash
# Single file
clang-tidy lib/src/main/jni/UVCCamera/FrameBufferRing.cpp \
    -- -std=c++20 -I... -DANDROID

# All files with fixes
clang-tidy lib/src/main/jni/UVCCamera/*.cpp --fix \
    -- -std=c++20 -I...
```

---

## AddressSanitizer Configuration

### Build Configuration (Android.mk)

```makefile
# Debug builds with ASan
ifeq ($(NDK_DEBUG),1)
    LOCAL_CFLAGS += -fsanitize=address -fno-omit-frame-pointer
    LOCAL_LDFLAGS += -fsanitize=address
endif
```

### Application.mk

```makefile
# Enable ASan for debug builds
ifeq ($(NDK_DEBUG),1)
    APP_CFLAGS += -fsanitize=address
    APP_LDFLAGS += -fsanitize=address
endif
```

### Runtime Configuration

```java
// Application.java or test setup
static {
    System.loadLibrary("asan");  // Must be first
    System.loadLibrary("UVCCamera");
}
```

---

## CI Integration Script

```bash
#!/bin/bash
# static-analysis.sh - Memory Safety CI Check
# Run from project root

set -e

echo "=== Cppcheck Analysis ==="
cppcheck --enable=warning,performance \
    --error-exitcode=1 \
    --suppress=missingIncludeSystem \
    --template='[{severity}] {file}:{line}: {message} [{id}]' \
    lib/src/main/jni/UVCCamera/*.cpp \
    lib/src/main/jni/UVCCamera/*.h

echo "=== clang-tidy Analysis ==="
find lib/src/main/jni/UVCCamera -name '*.cpp' | \
    xargs clang-tidy \
    --warnings-as-errors='bugprone-*,cert-*' \
    -- -std=c++20 -DANDROID

echo "=== All checks passed ==="
```

---

## Check Categories by Priority

### P0: Must Fix (Block Release)

| Check ID | Category | Description |
|----------|----------|-------------|
| bugprone-use-after-move | Use after free | Move semantics violation |
| bugprone-double-free | Double free | Memory freed twice |
| cert-err33-c | Error handling | Unchecked return value |
| clang-analyzer-core.NullDereference | Null deref | Null pointer dereference |

### P1: Should Fix (High Priority)

| Check ID | Category | Description |
|----------|----------|-------------|
| cppcoreguidelines-owning-memory | Ownership | Raw owning pointer |
| bugprone-sizeof-expression | Buffer size | Incorrect sizeof usage |
| cert-mem57-cpp | Memory | Alignment requirements |

### P2: Should Address (Medium Priority)

| Check ID | Category | Description |
|----------|----------|-------------|
| performance-unnecessary-copy | Performance | Unnecessary copies |
| modernize-use-nullptr | Modernize | Use nullptr |
| misc-redundant-expression | Logic | Redundant logic |

### P3: Style (Low Priority)

| Check ID | Category | Description |
|----------|----------|-------------|
| readability-identifier-naming | Naming | Naming conventions |
| modernize-use-auto | Modernize | Use auto where clear |

---

## Baseline Generation

To track progress and prevent regressions:

```bash
# Generate baseline
cppcheck --enable=all --xml --xml-version=2 \
    lib/src/main/jni/UVCCamera/ \
    2> docs/audit/baseline-$(date +%Y%m%d).xml

# Compare to baseline
cppcheck-diff baseline.xml current.xml --show-new
```

---

## Integration with Build System

### Gradle Integration (build.gradle.kts)

```kotlin
tasks.register("staticAnalysis") {
    doLast {
        exec {
            commandLine("cppcheck", "--enable=warning", "--error-exitcode=1",
                "lib/src/main/jni/UVCCamera/")
        }
    }
}

tasks.named("preBuild") {
    dependsOn("staticAnalysis")
}
```

### GitHub Actions

```yaml
- name: Static Analysis
  run: |
    brew install cppcheck
    cppcheck --enable=warning --error-exitcode=1 \
      lib/src/main/jni/UVCCamera/
```

---

## Summary

| Category | Issues Found | Action Required |
|----------|--------------|-----------------|
| **Critical (error)** | 2 | Investigate immediately |
| **Warning** | 4 | Fix before 2026 migration |
| **Style** | Many | Address opportunistically |

### Recommended Next Steps

1. **Immediate:** Investigate FrameBufferJNI.cpp deallocuse/doubleFree
2. **Near-term:** Add Rule of Five to PendingFrame
3. **Migration:** Initialize all members in constructors
4. **CI:** Add cppcheck to PR checks

---

*End of SAFETY-008*
