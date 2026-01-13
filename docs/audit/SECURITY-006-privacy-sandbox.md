# SECURITY-006: Privacy Sandbox Compliance Assessment

**Audit:** AUDIT-004 Android Security Compliance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

| Trigger Pattern | Count | Risk Level |
|-----------------|-------|------------|
| **Device enumeration (`opendir /dev`)** | 15+ | CRITICAL |
| **`libusb_get_device_list()`** | 1+ | CRITICAL |
| **USB descriptor read pre-permission** | Potential | HIGH |
| **System property fingerprinting** | 0 | ✅ COMPLIANT |
| **Hardware ID access** | Minimal | LOW |

**Overall Assessment:** Privacy Sandbox violations present in libusb layer. Direct device enumeration must be removed.

---

## Privacy Sandbox "Hidden Hardware Access" Detection

### What Triggers the Flag

Android 16 Privacy Sandbox monitors for:
1. **Device directory enumeration** - `opendir("/dev/*")`
2. **USB device listing** - Without prior UsbManager permission
3. **Serial number access** - Pre-permission descriptor reads
4. **Hardware fingerprinting** - Collecting unique device identifiers

### Consequences

| Severity | Consequence |
|----------|-------------|
| Warning | App flagged in Play Console |
| Moderate | Play Protect warning to users |
| Severe | App removal from Play Store |
| Critical | Process termination on device |

---

## Device Enumeration Patterns (CRITICAL)

### libusb android_usbfs.c

**Location:** `lib/src/main/jni/libusb/libusb/os/android_usbfs.c`

**Violations Found:**

```c
// Line 318 - Directory enumeration
dir = opendir(dirname);

// Line 322 - Reading directory entries
while ((entry = readdir(dir)) != NULL ) {

// Line 353 - Nested directory scan
dir = opendir(path);

// Line 1542 - USB bus enumeration
DIR *buses = opendir(usbfs_path);

// Line 1550 - Iterating USB buses
while ((entry = readdir(buses))) {

// Line 1599 - sysfs device enumeration
DIR *devices = opendir(SYSFS_DEVICE_PATH);
```

**Impact:**
- These patterns scan `/dev/bus/usb/` to discover USB devices
- On Android 16, SELinux blocks these operations
- Privacy Sandbox flags as "Unauthorized Peripheral Discovery"

---

### libusb linux_usbfs.c

**Location:** `lib/src/main/jni/libusb/libusb/os/linux_usbfs.c`

Similar patterns exist in the generic Linux backend (used as fallback).

---

## libusb_get_device_list() (CRITICAL)

**Location:** `lib/src/main/jni/libuvc/src/device.c:603`

```c
if (libusb_get_device_list(ctx->usb_ctx, &usb_dev_list) < 0) {
    // Error handling
}
```

**Privacy Sandbox Trigger:**
- Enumerates all USB devices
- Called before any permission is granted
- Classified as "Hidden Hardware Discovery"

---

## System Property Access

### Search Results

```bash
grep -rn '__system_property_get\|getprop' $JNI_PATH/UVCCamera --include="*.c" --include="*.cpp"
```

**Result:** No system property reads in UVCCamera core.

**Assessment:** ✅ COMPLIANT - No device fingerprinting via system properties.

---

## Hardware ID Access Patterns

### USB Serial Number

**Search:**
```bash
grep -rn 'serial\|SERIAL\|getSerial' $JNI_PATH/UVCCamera --include="*.c" --include="*.cpp"
```

**Result:** Minimal usage, only for device identification after permission granted.

**Assessment:** LOW RISK if accessed only post-permission.

### Device Descriptor Access

**Pattern in libuvc:**
```c
// device.c - Reading device descriptors
uvc_get_device_descriptor(dev, &desc);
```

**Risk:** If called before UsbManager.requestPermission(), triggers Privacy Sandbox flag.

---

## Compliant Alternative Patterns

### Device Discovery

**PROHIBITED:**
```cpp
// Native code enumerates devices
libusb_device** list;
libusb_get_device_list(ctx, &list);
for (int i = 0; list[i]; i++) {
    libusb_get_device_descriptor(list[i], &desc);
    if (desc.idVendor == target_vid) {
        // Found target device
    }
}
```

**COMPLIANT:**
```kotlin
// Kotlin handles discovery through framework
val devices = usbManager.deviceList.values.filter { device ->
    device.vendorId == TARGET_VID && device.productId == TARGET_PID
}

// Only after user grants permission
devices.forEach { device ->
    if (usbManager.hasPermission(device)) {
        val connection = usbManager.openDevice(device)
        nativeInit(connection.fileDescriptor)
    }
}
```

### Serial Number Access

**PROHIBITED:**
```cpp
// Reading serial before permission
char serial[256];
libusb_get_string_descriptor_ascii(handle, desc.iSerialNumber, serial, 256);
```

**COMPLIANT:**
```kotlin
// Only access serial after permission granted
if (usbManager.hasPermission(device)) {
    val serial = device.serialNumber  // Framework provides
    // Or read via open connection
}
```

---

## Privacy Sandbox Compliance Matrix

| Operation | Pre-Permission | Post-Permission | Notes |
|-----------|---------------|-----------------|-------|
| List USB devices | ❌ BLOCKED | ✅ Via UsbManager | Use framework API |
| Open USB device | ❌ BLOCKED | ✅ Via UsbManager | Get FD from framework |
| Read serial | ❌ BLOCKED | ✅ After grant | UsbDevice.serialNumber |
| Read descriptors | ❌ BLOCKED | ✅ After open | Via open connection |
| Enumerate `/dev/` | ❌ ALWAYS | ❌ ALWAYS | Never scan device directories |
| System properties | ⚠️ Limited | ⚠️ Limited | Avoid fingerprinting |

---

## Migration Requirements

### Phase 1: Remove Directory Enumeration

**In libusb:**
- Remove or disable `usbfs_scan_busdir()`
- Remove or disable `sysfs_scan_device()`
- The `libusb_init2(usbfs)` approach bypasses some of this but not completely

**Alternative:** Use FD injection exclusively (see SECURITY-002)

### Phase 2: Remove libusb_get_device_list()

**In libuvc:**
- Remove `uvc_find_device()` function
- Remove `uvc_get_device_list()` function
- Replace with `uvc_open_from_fd()` pattern

### Phase 3: Audit Descriptor Access

Ensure all USB descriptor reads happen AFTER:
1. User grants permission via UsbManager
2. FD is obtained from UsbDeviceConnection
3. Native code receives FD via JNI

---

## Testing Strategy

### Privacy Sandbox Detection Test

```kotlin
@Test
fun testNoHiddenHardwareAccess() {
    // Monitor logcat for Privacy Sandbox warnings
    val process = Runtime.getRuntime().exec(
        arrayOf("logcat", "-d", "-s", "PrivacySandbox:*")
    )
    val output = process.inputStream.bufferedReader().readText()

    // Should not contain hidden hardware access warnings
    assertFalse(output.contains("HiddenHardwareAccess"))
    assertFalse(output.contains("UnauthorizedPeripheralDiscovery"))
}
```

### SELinux Denial Check

```bash
# Run on Android 16 device
adb logcat | grep -E "avc.*denied.*usb|avc.*denied.*dev"

# Should see NO denials after migration
```

---

## Play Store Compliance

### Pre-Declaration Requirements

If app must enumerate devices (not recommended), declare in Data Safety:
- "Collects device identifiers"
- "For app functionality"

### Post-Migration Benefits

With FD injection, app:
- Does NOT enumerate devices
- Does NOT access serial numbers pre-permission
- Does NOT trigger Privacy Sandbox flags
- Has cleaner Play Store compliance story

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-001** | USB access patterns to remove |
| **SECURITY-002** | FD injection alternative |
| **SECURITY-010** | Privacy threat model |
| **AUDIT-004 Appendix F** | Full Privacy Sandbox triggers |

---

*End of SECURITY-006*
