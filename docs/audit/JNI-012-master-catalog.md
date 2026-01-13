# JNI-012: Master Catalog

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** Consolidated JNI audit findings
**Status:** Complete

---

## Summary

| Metric | Value |
|--------|-------|
| Total Findings | 50 |
| Info Severity | 38 |
| Low Severity | 10 |
| Medium Severity | 2 |
| Documents Covered | 10 (JNI-001 through JNI-010) |

---

## 1. Severity Distribution

```
┌──────────────────────────────────────────────────────────────────────┐
│                    FINDING SEVERITY DISTRIBUTION                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  Info:   ████████████████████████████████████████ 38 (76%)           │
│  Low:    ████████████ 10 (20%)                                       │
│  Medium: ████ 2 (4%)                                                  │
│  High:   0 (0%)                                                       │
│  Crit:   0 (0%)                                                       │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. Category Breakdown

| Category | Total | Info | Low | Medium |
|----------|-------|------|-----|--------|
| Function Inventory | 6 | 4 | 1 | 1 |
| Handle Leaks | 6 | 3 | 1 | 2 |
| Frame Delivery | 6 | 5 | 1 | 0 |
| Lifecycle | 6 | 5 | 1 | 0 |
| Error Handling | 5 | 4 | 1 | 0 |
| Thread Attachment | 5 | 4 | 1 | 0 |
| AHardwareBuffer | 5 | 4 | 1 | 0 |
| Handle Registry | 5 | 4 | 1 | 0 |
| Interface Spec | 5 | 4 | 1 | 0 |
| Migration Bridge | 5 | 4 | 1 | 0 |

---

## 3. Action Items

### 3.1 Medium Severity (Requires Attention)

| ID | Finding | Location | Recommendation |
|----|---------|----------|----------------|
| JNI-001-003 | EGL handles use direct cast | EGLImageHelperJNI.cpp:282 | Migrate to HandleManager |
| JNI-002-003 | EGLImage handle uses direct cast | EGLImageHelperJNI.cpp:282 | Consider HandleManager |
| JNI-002-004 | EGLSync handle uses direct cast | EGLImageHelperJNI.cpp:419 | Consider HandleManager |

**Note:** JNI-001-003 and JNI-002-003 reference the same underlying issue.

### 3.2 Low Severity (Track)

| ID | Finding | Status |
|----|---------|--------|
| JNI-001-005 | WhiteBlance typo preserved | Accepted - legacy compatibility |
| JNI-002-005 | Internal ring pointer returned | Accepted - internal use only |
| JNI-003-003 | Legacy ByteBuffer path retained | Deferred - deprecation path |
| JNI-004-004 | GlobalRef cleanup relies on destructor | Accepted - standard pattern |
| JNI-005-004 | No JNI exceptions thrown | Deferred - return codes sufficient |
| JNI-006-003 | Threads unnamed | Deferred - optional enhancement |
| JNI-007-004 | API 29+ recommended | Accepted - documented |
| JNI-008-004 | 64-slot limit | Accepted - sufficient |
| JNI-009-004 | 81 control methods | Deferred - codegen future work |
| JNI-010-003 | Legacy IFrameCallback retained | Deferred - deprecation path |

---

## 4. Status Summary

| Status | Count | Description |
|--------|-------|-------------|
| Verified | 38 | Finding confirmed, no action needed |
| Accepted | 6 | Finding acknowledged, no change planned |
| Deferred | 4 | Acknowledged, scheduled for future |
| Open | 2 | Requires attention (EGL handles) |

---

## 5. Key Positive Findings

### 5.1 Modern Architecture ✓

| Pattern | Evidence |
|---------|----------|
| HandleManager | 100% of camera/ring methods use ScopedRef |
| Zero-copy | AHardwareBuffer + EGL pipeline implemented |
| MTE-safe | Generation-encoded handles, no raw pointers |
| Thread-safe | Atomic state, proper memory ordering |

### 5.2 Robust Error Handling ✓

| Pattern | Evidence |
|---------|----------|
| Handle validation | 154+ methods validate before use |
| Exception clearing | 22 ExceptionClear calls |
| Consistent returns | 0 = success, -100 = invalid handle |

### 5.3 Clean Lifecycle ✓

| Pattern | Evidence |
|---------|----------|
| 3-state machine | COLD/WARM/HOT for preview |
| 4-level cleanup | PREVIEW_ONLY → FULL gradient |
| GlobalRef tracking | 5 callback types managed |

---

## 6. Recommendations

### 6.1 Immediate (Medium Priority)

```
EGL Handle Migration (Optional)
─────────────────────────────────
Location: EGLImageHelperJNI.cpp:282, 419
Issue: Direct reinterpret_cast exposes EGL handles
Risk: Medium - Kotlin must ensure destroy() called

Option A: Create EGL HandleManager
Option B: Document Kotlin lifecycle requirements (current)

Mitigating factors:
- EGL handles are opaque integers, not heap pointers
- Android EGL driver manages actual resources
- No MTE tag stripping issues
```

### 6.2 Future (Low Priority)

| Item | Document | Notes |
|------|----------|-------|
| Codegen for camera controls | JNI-001, JNI-009 | 81 methods follow same pattern |
| Thread naming | JNI-006 | JavaVMAttachArgs for debugging |
| IFrameCallback deprecation | JNI-003, JNI-010 | Phase 2/3 of migration |

---

## 7. Cross-Reference

| Document | Purpose |
|----------|---------|
| JNI-001 | Function inventory (160 methods) |
| JNI-002 | Handle leak analysis |
| JNI-003 | Frame delivery patterns |
| JNI-004 | Lifecycle state machines |
| JNI-005 | Error handling assessment |
| JNI-006 | Thread attachment audit |
| JNI-007 | AHardwareBuffer design |
| JNI-008 | Handle registry implementation |
| JNI-009 | 2026 interface specification |
| JNI-010 | Migration bridge design |

---

## 8. Data File

Full catalog in CSV format: `JNI-012-master-catalog.csv`

**Columns:**
- id: Finding identifier
- document: Source document
- category: Finding category
- severity: Info/Low/Medium/High/Critical
- finding: Description
- recommendation: Action item
- status: Verified/Accepted/Deferred/Open
- notes: Additional context

---

*End of JNI-012*
