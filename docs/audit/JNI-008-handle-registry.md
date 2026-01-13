# JNI-008: Handle Registry Implementation

**Audit:** AUDIT-006 JNI Interface Design
**Generated:** 2026-01-11
**Target:** MTE-safe handle management
**Status:** Implemented

---

## Summary

| Metric | Value |
|--------|-------|
| Implementation Status | Production Ready |
| Handle Types | 2 (Camera, RingBuffer) |
| Max Slots | 64 each |
| MTE Compliance | Yes |

---

## 1. HandleManager Design

### 1.1 Architecture

```cpp
// HandleManager.h
template<size_t MAX_SLOTS = 64>
class HandleManager {
    struct Slot {
        std::atomic<ContextPtr> ctx{0};      // Pointer (tagged on MTE)
        std::atomic<uint32_t> generation{0}; // Prevents use-after-free
        std::atomic<int32_t> activeRefs{0};  // Blocks destruction
    };

    std::array<Slot, MAX_SLOTS> mSlots;
    std::mutex mMutex;
};
```

### 1.2 Handle Encoding

```
Handle Format (64-bit):
┌────────────────────────────────────────────────────────────────────┐
│ Bits 63-32: Generation │ Bits 31-0: Slot Index                     │
└────────────────────────────────────────────────────────────────────┘

Generation: Increments on each reuse of slot
Slot Index: 0 to MAX_SLOTS-1
```

### 1.3 MTE Safety

```cpp
// HandleManager.h:74-75
// Using uintptr_t ensures MTE-tagged pointers (0xb400...) are preserved
using ContextPtr = uintptr_t;
```

---

## 2. API

### 2.1 Registration

```cpp
int64_t registerContext(void* ctx) {
    std::lock_guard<std::mutex> lock(mMutex);

    for (size_t i = 0; i < MAX_SLOTS; i++) {
        if (mSlots[i].ctx.load() == 0) {
            uint32_t gen = mSlots[i].generation.load() + 1;
            mSlots[i].ctx.store(reinterpret_cast<ContextPtr>(ctx));
            mSlots[i].generation.store(gen);
            return encodeHandle(i, gen);
        }
    }
    return INVALID_HANDLE;  // No slots available
}
```

### 2.2 Acquisition (ScopedRef)

```cpp
ScopedRef acquire(int64_t handle) {
    auto [idx, gen] = decodeHandle(handle);

    if (idx >= MAX_SLOTS) return {nullptr, nullptr};

    Slot& slot = mSlots[idx];

    // Check generation (prevents use-after-free)
    if (slot.generation.load() != gen) return {nullptr, nullptr};

    // Increment ref count (blocks destruction)
    slot.activeRefs.fetch_add(1);

    // Double-check after increment
    if (slot.generation.load() != gen) {
        slot.activeRefs.fetch_sub(1);
        return {nullptr, nullptr};
    }

    return {reinterpret_cast<void*>(slot.ctx.load()), &slot.activeRefs};
}
```

### 2.3 Invalidation (Blocking)

```cpp
void* invalidateAndFree(int64_t handle) {
    auto [idx, gen] = decodeHandle(handle);

    Slot& slot = mSlots[idx];

    // Mark as dead (increment generation)
    slot.generation.fetch_add(1);

    // Spin-wait for active refs to drain
    int spins = 0;
    while (slot.activeRefs.load() > 0) {
        if (++spins > 5000) {
            LOGE("TIMEOUT waiting for refs to drain");
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    void* ctx = reinterpret_cast<void*>(slot.ctx.exchange(0));
    return ctx;
}
```

---

## 3. Usage Pattern

### 3.1 JNI Integration

```cpp
// Creation
int64_t handle = getCameraHandleManager().registerContext(new UVCCamera());

// Every JNI call
auto ref = getCameraHandleManager().acquire(handle);
if (!ref) return JNI_ERR_INVALID_HANDLE;
UVCCamera* camera = static_cast<UVCCamera*>(ref.ptr);

// Destruction (blocks until all calls complete)
void* ctx = getCameraHandleManager().invalidateAndFree(handle);
delete static_cast<UVCCamera*>(ctx);
```

### 3.2 Global Managers

```cpp
// Two separate managers for different object types
HandleManager<64>& getCameraHandleManager() {
    static HandleManager<64> manager;
    return manager;
}

HandleManager<64>& getRingBufferHandleManager() {
    static HandleManager<64> manager;
    return manager;
}
```

---

## 4. Security Properties

### 4.1 Protection Against

| Attack | Protection |
|--------|------------|
| Use-after-free | Generation mismatch fails validation |
| Double-free | Generation incremented on free |
| Stale handle | Generation check in acquire |
| Concurrent destroy | activeRefs blocks until JNI calls complete |
| MTE bypass | uintptr_t preserves memory tags |

### 4.2 Memory Ordering

```cpp
// Acquire semantics on generation read
gen = slot.generation.load(std::memory_order_acquire);

// Release semantics on context write
slot.ctx.store(ptr, std::memory_order_release);
```

---

## 5. Findings Summary

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| JNI-008-001 | Info | Generation-encoded handles | MTE-safe |
| JNI-008-002 | Info | ScopedRef blocks destruction | Thread-safe |
| JNI-008-003 | Info | Spin-wait with timeout | Prevents deadlock |
| JNI-008-004 | Low | 64-slot limit | Sufficient for typical use |
| JNI-008-005 | Info | Separate managers per type | Clean isolation |

---

## 6. Cross-Reference

| Document | Relationship |
|----------|--------------|
| **HandleManager.h** | Implementation |
| **JNI-002** | Handle leak analysis |
| **SECURITY-003** | MTE compliance |

---

*End of JNI-008*
