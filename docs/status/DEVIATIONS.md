# Implementation Deviations Log

**Purpose:** Track any deviations from ARCH-DECISIONS-001-R2 discovered during implementation.

---

## Deviation Categories

| Category | Description | Action Required |
|----------|-------------|-----------------|
| **TACTICAL** | Minor implementation difference, same outcome | Document only |
| **TECHNICAL** | Technical limitation prevents exact implementation | Propose alternative |
| **ARCHITECTURAL** | Affects multiple decisions or principles | Requires ADR amendment |
| **DISCOVERY** | New information changes assumptions | May require re-planning |

---

## Active Deviations

*No active deviations.*

<!-- Template for new deviations:

### DEV-001: Short Description

**Category:** TACTICAL / TECHNICAL / ARCHITECTURAL / DISCOVERY
**Discovered:** 2026-01-XX
**Phase:** X
**Task:** X.X
**Affects Decision:** DECISION-XXX

#### Original Plan

What the ADR/imp-plan specified.

#### Actual Situation

What was discovered during implementation.

#### Deviation Details

Specific differences from the plan.

#### Impact Assessment

- **Scope:** This task only / Multiple tasks / Phase / Project
- **Risk:** Low / Medium / High
- **Blocking:** Yes / No

#### Proposed Resolution

How to proceed.

#### Resolution Status

- [ ] Documented
- [ ] Alternative approved
- [ ] Implemented
- [ ] Verified

#### Notes

Additional context.

-->

---

## Resolved Deviations

*No resolved deviations.*

---

## Deviation Statistics

| Category | Active | Resolved | Total |
|----------|--------|----------|-------|
| TACTICAL | 0 | 0 | 0 |
| TECHNICAL | 0 | 0 | 0 |
| ARCHITECTURAL | 0 | 0 | 0 |
| DISCOVERY | 0 | 0 | 0 |

---

## Escalation Guidelines

### When to Escalate

1. **ARCHITECTURAL** deviations always escalate
2. **TECHNICAL** deviations blocking Phase completion
3. **DISCOVERY** that invalidates assumptions
4. Any deviation affecting 3+ tasks

### Escalation Process

1. Mark affected task with `[!]` in IMPLEMENTATION-STATUS.md
2. Create deviation entry here
3. Add to "Blocking Issues" section in status
4. Wait for resolution before proceeding

---

## ADR Amendment Proposals

*No amendment proposals pending.*

<!-- Template:

### AMEND-001: Proposed Amendment

**Related Deviation:** DEV-XXX
**Affects Decision:** DECISION-XXX
**Proposed Change:** Description

**Rationale:**
Why the amendment is needed.

**Status:** Proposed / Approved / Rejected / Implemented

-->

---

*This file tracks deviations from the authoritative architectural decisions.*
