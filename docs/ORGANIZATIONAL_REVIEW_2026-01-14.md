# Organizational Review: 2026-01-14

**Purpose:** Comprehensive review of project organization, documentation alignment, and roadmap clarity.

---

## Executive Summary

### Project Role (Confirmed)

**uvccamera-experimental** is a **SANDBOX** for:
- Testing UVC library improvements in isolation
- Generating patches and documentation for scopecam-engine
- Providing architectural directives for consumer application development

**NOT for:**
- Production binaries
- Direct binary syncing to scopecam-engine

### Current State

| Area | Status |
|------|--------|
| **Phase 0-Pre** | ✅ COMPLETE |
| **Phase 0** | ✅ INTEGRATED (awaiting device testing) |
| **Phase 1** | 🔄 Tasks 1.1-1.3 complete, 1.4-1.5 pending |
| **App Integration** | 🔴 ACTIVE - Major directives issued |
| **Documentation** | ⚠️ Needs organization |

---

## Issues Identified

### 1. Documentation Structure

| Issue | Impact | Resolution |
|-------|--------|------------|
| `IMPLEMENTATION-STATUS.md` outdated | Doesn't reflect video recording work | Update with current state |
| `docs/README.md` outdated | Missing directive references | Update with current links |
| Audit files in `docs/` root | Clutters main docs | Already in `docs/audit/` ✅ |
| Multiple audit-*.md in root | Historical clutter | Move to archive |
| `DIRECTIVE_TO_SCOPECAM_ENGINE.md` superseded | Confusing | Mark as superseded |

### 2. Patches Directory

| File | Status | Action |
|------|--------|--------|
| `SCOPECAM_ENGINE_WARM_GATE_DIRECTIVE.md` | R2 - Current | Keep (surface lease) |
| `SCOPECAM_ENGINE_VIDEO_RECORDING_DIRECTIVE.md` | R3 - Current | Keep (recording) |
| `DIRECTIVE_TO_SCOPECAM_ENGINE.md` | Superseded | Archive or delete |
| `INTEGRATION_CONFIRMED.md` | Historical | Keep for audit trail |
| `SUBMISSION_STATUS.md` | Historical | Keep for audit trail |
| `*.patch` files | Current | Keep |

### 3. ADR/Roadmap Alignment

| Document | Issue | Resolution |
|----------|-------|------------|
| `adr-proposal.md` | Missing DECISION-023 (Session Truth) | Add decision |
| `imp-plan.md` | References deprecated sync | Update |
| Phase dependencies | Out of sync with actual work | Clarify |

### 4. Cross-Project Relationship

**Current directives issued to scopecam-engine:**

| Directive | Version | Content |
|-----------|---------|---------|
| `SCOPECAM_ENGINE_WARM_GATE_DIRECTIVE.md` | R2 | Surface lease, FD truth, SurfaceLeaseController |
| `SCOPECAM_ENGINE_VIDEO_RECORDING_DIRECTIVE.md` | R3 | HOT gate, capture commit, RecordingCoordinator |

**Native requirements identified:**
1. Idempotent surface operations
2. PIPELINE_READY log point
3. Deterministic stagnant definition
4. NativeSnapshot support

---

## Recommended Organization

### Documentation Hierarchy

```
docs/
├── README.md                           # Quick start + index
├── architecture.md                     # System architecture
├── api-reference.md                    # Public API
├── ScopeCam-Integration-Guide.md       # Consumer app integration
├── PROMOTION_WORKFLOW.md               # Patch promotion process
│
├── status/
│   ├── IMPLEMENTATION-STATUS.md        # Current progress
│   └── DEVIATIONS.md                   # Deviations from plan
│
├── phase-docs/
│   ├── PHASE_0_COMPLETION.md           # Phase 0 summary
│   ├── PHASE_1_PROGRESS.md             # Phase 1 progress
│   ├── PTS_SCR_PLUMBING.md             # PTS/SCR implementation
│   ├── PTS_RELIABILITY_REPORT.md       # Test results
│   ├── THREAD_PRIORITY.md              # Thread priority implementation
│   └── TASK_1.3_EMPIRICAL_INFERENCE_PLAN.md
│
├── audit/                              # Security/code audits (existing)
│   └── (50+ audit files)
│
└── archive/                            # Historical documents
    ├── audit-*.md                      # Old audit summaries
    ├── CURRENT-STATUS.md               # Superseded by status/
    ├── MODERNIZATION-PLAN.md           # Historical planning
    └── opportunity-plan.md             # Historical planning
```

### Patches Hierarchy

```
patches/
├── directives/                         # Binding directives to scopecam-engine
│   ├── SCOPECAM_ENGINE_WARM_GATE_DIRECTIVE.md (R2)
│   └── SCOPECAM_ENGINE_VIDEO_RECORDING_DIRECTIVE.md (R3)
│
├── code/                               # Actual patch files
│   ├── libuvc-pts-scr-plumbing.patch
│   ├── thread-priority.patch
│   └── tl-expected-integration.patch
│
└── archive/                            # Historical/superseded
    ├── DIRECTIVE_TO_SCOPECAM_ENGINE.md (superseded)
    ├── INTEGRATION_CONFIRMED.md
    └── SUBMISSION_STATUS.md
```

---

## Roadmap Clarification

### Current Focus (2026-01-14)

**Two parallel tracks:**

1. **Native Library Development (Phases 1-4)**
   - Phase 1.4-1.5: GET_INFO verification, structured errors
   - Phase 2: Clock synchronizer, quality ladder
   - Phase 3: H.264/HEVC pipeline
   - Phase 4: XU framework

2. **App Integration Support (Active)**
   - Issue directives for scopecam-engine architectural issues
   - Define cross-project contracts
   - Document integration patterns

### Native Requirements for App Support

| Requirement | Status | Phase |
|-------------|--------|-------|
| `getPreviewState()` | ✅ Exists | - |
| `querySessionDiagnostic()` | ✅ Exists | - |
| `suspendSurfaceLease()` | ✅ Exists | - |
| `acquireSurfaceLease()` | ✅ Exists | - |
| Idempotent surface ops | ⚠️ Needs logging | Native |
| PIPELINE_READY log point | ⚠️ Not implemented | Native |
| Stagnant well-defined | ✅ Exists (500ms) | - |

---

## Action Items

### Immediate (This Session)

1. ✅ Update `docs/status/IMPLEMENTATION-STATUS.md` with:
   - Video recording directive work
   - HOT gate contract
   - Capture commit pattern
   - Current native requirements

2. ✅ Update `docs/README.md` with:
   - Directive references
   - Current project focus

3. ✅ Add DECISION-023 to `adr-proposal.md`

4. ✅ Update `CLAUDE.md` phase dependencies

### Deferred (Future Session)

1. Reorganize patches directory structure
2. Move historical docs to archive
3. Create phase-docs subdirectory
4. Implement PIPELINE_READY log point in native

---

## Success Criteria

After this session, the project should have:

1. **Clear current state** - Anyone can understand what's done and what's in progress
2. **Accurate roadmap** - Phase dependencies reflect actual work
3. **Consistent documentation** - No contradictions between documents
4. **Clear cross-project boundary** - Native vs Kotlin responsibilities documented
5. **Up-to-date status** - IMPLEMENTATION-STATUS.md reflects current reality

---

*This review identifies organizational issues. Implementation follows.*
