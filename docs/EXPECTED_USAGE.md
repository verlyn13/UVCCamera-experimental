# tl::expected Integration

**Status:** Integrated (Phase 0, DECISION-016)
**Date:** 2026-01-13

## Summary

`tl::expected<T, E>` is a C++17-compatible implementation of the proposed `std::expected` type,
providing a way to return either a value (on success) or an error (on failure) without exceptions.

## Location

| File | Purpose |
|------|---------|
| `third_party/tl/expected.hpp` | Vendored tl::expected implementation |
| `include/uvc/expected.h` | UVC namespace alias wrapper |

## Usage

### Include Header

```cpp
#include "uvc/expected.h"
```

### Basic Usage

```cpp
#include "uvc/expected.h"

enum class UvcError {
    InvalidParameter,
    DeviceNotFound,
    PermissionDenied,
    Timeout
};

// Function returning expected
uvc::expected<uint32_t, UvcError> get_camera_resolution() {
    // On success:
    return 1920;

    // On error:
    return uvc::unexpected(UvcError::DeviceNotFound);
}

// Consuming the result
void example() {
    auto result = get_camera_resolution();

    if (result) {
        uint32_t width = *result;
        // Use width...
    } else {
        UvcError error = result.error();
        // Handle error...
    }
}
```

### Using value_or

```cpp
uvc::expected<int, UvcError> get_timeout();

void example() {
    // Returns value or default if error
    int timeout = get_timeout().value_or(1000);
}
```

### Chaining with and_then/transform

```cpp
uvc::expected<std::string, UvcError> get_device_name();

void example() {
    auto result = get_device_name()
        .transform([](const std::string& name) {
            return name.length();  // Transform to length
        });

    if (result) {
        size_t len = *result;
    }
}
```

### Error Propagation Pattern

```cpp
uvc::expected<Frame, UvcError> process_frame(uvc_frame_t* raw) {
    if (!raw) {
        return uvc::unexpected(UvcError::InvalidParameter);
    }

    auto validated = validate_frame(raw);
    if (!validated) {
        return uvc::unexpected(validated.error());  // Propagate error
    }

    return Frame{*validated};
}
```

## Namespace

The UVC wrapper provides:

```cpp
namespace uvc {
    template<typename T, typename E>
    using expected = tl::expected<T, E>;

    using tl::unexpected;
    using tl::unexpect;
    using tl::unexpect_t;
    using tl::bad_expected_access;
}
```

## When to Use

### Use expected for:
- Functions that can fail in expected ways
- Replacing C-style error codes (`int` returns)
- Replacing output parameters (`void foo(int* result, int* error)`)
- When errors should be handled, not ignored

### Don't use expected for:
- Performance-critical hot paths (has overhead)
- Simple boolean success/failure (use `bool`)
- Unrecoverable errors (use exceptions or abort)

## Integration with Existing Code

When wrapping existing libuvc functions:

```cpp
// Existing C API:
// uvc_error_t uvc_get_ae_mode(uvc_device_handle_t *devh, uint8_t* mode, enum uvc_req_code req_code);

// C++ wrapper using expected:
uvc::expected<uint8_t, uvc_error_t> get_ae_mode(uvc_device_handle_t* devh, uvc_req_code req_code) {
    uint8_t mode;
    uvc_error_t err = uvc_get_ae_mode(devh, &mode, req_code);
    if (err != UVC_SUCCESS) {
        return uvc::unexpected(err);
    }
    return mode;
}
```

## Benefits

1. **Type-safe error handling**: Compiler enforces checking return values
2. **Clear intent**: Function signature shows it can fail
3. **Composability**: Chain operations with and_then/transform
4. **No exceptions**: Works in -fno-exceptions environments
5. **Zero-overhead happy path**: No exception handling overhead on success

## Breaking Changes

None. This is an additive feature.

## ADR Reference

Implements DECISION-016 from ARCH-DECISIONS-001-R1.
