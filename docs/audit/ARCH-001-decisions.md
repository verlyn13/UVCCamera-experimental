# ARCH-001: Architectural Decisions Record

**Audit:** AUDIT-005/AUDIT-006 Build System & JNI Design
**Generated:** 2026-01-11
**Status:** Authoritative Reference

---

## Summary

This document records key architectural decisions derived from official Android NDK documentation and best practices for 2026 development.

---

## 1. Build System Selection

### Decision: Gradle + CMake for New Applications

**Recommendation:** For a new application in 2026, default to **Gradle + externalNativeBuild + CMake** because it keeps you closest to the mainstream ecosystem and makes "add a new ABI / toolchain tweak" less painful over time.

**Alternative:** Use **ndk-build** when you have legacy Android.mk assets you don't want to rewrite yet, or you're maintaining an existing NDK project.

**Rationale:**
- CMake is the industry standard for cross-platform C++ builds
- Better IDE integration (Android Studio, CLion, VS Code)
- Modern target-based dependency management
- ndk-build is **NOT deprecated** - it's still a valid choice for legacy projects

### Application to UVCCamera

| Factor | Current State | Recommendation |
|--------|---------------|----------------|
| Build System | ndk-build | Keep ndk-build (legacy assets) |
| Migration | Optional | Only if IDE integration is needed |
| New Features | Add to Android.mk | Can add to Android.mk |

---

## 2. Float ABI Configuration (armeabi-v7a)

### Decision: Keep softfp (NDK Default)

**Official NDK Documentation:**
> "For historical reasons armeabi-v7a uses `-mfloat-abi=softfp`, which changes the calling convention (how floats/doubles are passed), but the compiler still uses hardware floating-point instructions for arithmetic."

**Critical Understanding:**
- `softfp` does NOT mean "software floating point"
- Hardware FPU **is used** for arithmetic operations
- Only the **calling convention** differs (floats passed in integer registers)
- This ensures ABI compatibility with system libraries

### Architectural Implication

**DO NOT** "clean up" by forcing hard-float flags unless you really know what you're doing across your whole native dependency graph. ABI mismatches here are a classic source of weird crashes.

| Action | Status |
|--------|--------|
| Override to -mfloat-abi=hard | **PROHIBITED** |
| Keep NDK default (softfp) | **REQUIRED** |
| Document in BUILD-007 | Done |

---

## 3. Security Hardening (_FORTIFY_SOURCE)

### Decision: Rely on NDK Defaults

**Official NDK Build System Maintainers Guide:**
> "You enable Fortify by defining `_FORTIFY_SOURCE=2`. ndk-build and the NDK's CMake toolchain file enable this option by default."

### Architectural Implication

For a new app, you generally should NOT override/disable this. Instead:

1. Make sure your build logs confirm it's active
2. Focus on fixing any warnings/errors it surfaces
3. Never add `-U_FORTIFY_SOURCE` or `-D_FORTIFY_SOURCE=0`

| Setting | Value | Source |
|---------|-------|--------|
| _FORTIFY_SOURCE | 2 | NDK default |
| Stack Protector | -fstack-protector-strong | NDK default |
| RELRO | Full (-Wl,-z,relro,-z,now) | NDK default |

---

## 4. MTE (Memory Tagging Extension) Configuration

### Decision: Use armv8-a+memtag (NOT armv9-a baseline)

**Official Android MTE Documentation:**
```bash
-march=armv8-a+memtag
-fsanitize=memtag-stack,memtag-heap
```

**Critical Understanding:**
- MTE is a **capability extension** to ARMv8-A
- It does NOT require ARMv9-A baseline
- It's available on ARMv8.5-A and later (Pixel 8+ era)

### Architectural Implication

Treat MTE as a capability you can enable **per-build / per-device**, not as a reason to globally raise your baseline ISA.

**Design Pattern:**
- MTE builds are a **variant** (debug, internal, partner-testing)
- Non-MTE builds remain the primary shipping target
- Use build variants or feature flags to select

| Build Type | MTE | Target Devices |
|------------|-----|----------------|
| Release | OFF | All ARM64 devices |
| Debug-MTE | ON | Pixel 8+, Tensor G3+ |
| Partner-Test | ON | MTE-capable test devices |

### Implementation

```cmake
# CMake MTE variant configuration
option(ENABLE_MTE "Enable Memory Tagging Extension" OFF)

if(ENABLE_MTE AND ANDROID_ABI STREQUAL "arm64-v8a")
    target_compile_options(UVCCamera PRIVATE
        -march=armv8-a+memtag
        -fsanitize=memtag-stack,memtag-heap
    )
    target_link_options(UVCCamera PRIVATE
        -fsanitize=memtag-stack,memtag-heap
    )
endif()
```

---

## 5. RISC-V Support Status

### Decision: Design for Portability, Don't Ship riscv64 Yet

**Platform Side:** Android 16's Compatibility Definition explicitly allows devices to report `riscv64` among the supported ABIs list.

**NDK Side:** The Android NDK "Android ABIs" page enumerates the ABIs the NDK supports:
- armeabi-v7a ✓
- arm64-v8a ✓
- x86 ✓
- x86_64 ✓
- **riscv64 NOT LISTED**

### Architectural Implication

If you ship native code, you should architect for portability:
- Clean C/C++ code
- Minimize arch-specific assembly
- Keep build flags centralized

**But:** Treat riscv64 as **NOT a production NDK app ABI yet** (based on the NDK's own "supported ABIs" doc).

| ABI | Production Status | Action |
|-----|-------------------|--------|
| arm64-v8a | Primary target | Ship |
| armeabi-v7a | Legacy support | Ship |
| x86_64 | Emulator testing | Optional |
| x86 | Legacy emulator | Optional |
| riscv64 | **NOT SUPPORTED** | Do not add |

---

## 6. Summary: 2026 Best Practices

### Build Configuration

| Aspect | Recommendation |
|--------|----------------|
| Build System | Gradle + CMake (new) / ndk-build (legacy) |
| Hardening | Assume _FORTIFY_SOURCE=2 + stack protector ON |
| ABI Focus | arm64-v8a first, include others intentionally |
| Float ABI | Keep NDK default (softfp for v7a) |

### Security Configuration

| Aspect | Recommendation |
|--------|----------------|
| MTE | Compile as variant (-march=armv8-a+memtag) |
| NOT global armv9 | Keep armv8-a baseline for compatibility |
| Fortify | Never disable, fix warnings instead |

### Future-Proofing

| Aspect | Recommendation |
|--------|----------------|
| RISC-V | Design portable, don't ship yet |
| 16KB Pages | Already configured (APP_LDFLAGS) |
| CMake Migration | Optional, keep parallel builds |

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **BUILD-006** | Security flag verification |
| **BUILD-007** | ABI analysis (float ABI) |
| **BUILD-009** | CMake migration strategy |
| **BUILD-010** | CMake template (MTE variant) |
| **SECURITY-007** | MTE compatibility |

---

*End of ARCH-001*
