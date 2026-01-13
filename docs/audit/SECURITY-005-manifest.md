# SECURITY-005: Manifest Permission Audit

**Audit:** AUDIT-004 Android Security Compliance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/AndroidManifest.xml`

---

## Executive Summary

| Category | Status | Action Required |
|----------|--------|-----------------|
| **USB Permissions** | ⚠️ PARTIAL | Add FGS permissions |
| **USB Feature** | ✅ DECLARED | Optional (correct) |
| **Camera Permission** | ✅ DECLARED | N/A |
| **Foreground Service** | ❌ MISSING | **CRITICAL** |
| **Storage Permissions** | ✅ Not needed | Modern approach |

**Overall Assessment:** Manifest requires updates for Android 14+ Foreground Service requirements.

---

## Current Manifest Content

**Location:** `lib/src/main/AndroidManifest.xml`

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.CAMERA" />
    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <uses-feature android:name="android.hardware.usb.host" android:required="false" />

</manifest>
```

---

## Required Additions

### USB Session Persistence (CRITICAL)

For Android 14+ (API 34+), USB connections drop when:
- Screen locks (with Advanced Data Protection)
- App goes to background without Foreground Service

**Required Permissions:**
```xml
<!-- Base Foreground Service permission -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>

<!-- Type-specific permission (Android 14+) -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>

<!-- Notification permission (Android 13+) -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

**Service Declaration:**
```xml
<application>
    <service
        android:name=".UsbCameraService"
        android:foregroundServiceType="connectedDevice"
        android:exported="false">
        <intent-filter>
            <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"/>
        </intent-filter>
        <meta-data
            android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
            android:resource="@xml/device_filter"/>
    </service>
</application>
```

---

## Permission Analysis Matrix

### Required Permissions

| Permission | Android Version | Purpose | Status |
|------------|----------------|---------|--------|
| `CAMERA` | All | Camera preview | ✅ Declared |
| `FOREGROUND_SERVICE` | 9+ (API 28) | Run FGS | ❌ Missing |
| `FOREGROUND_SERVICE_CONNECTED_DEVICE` | 14+ (API 34) | USB FGS type | ❌ Missing |
| `POST_NOTIFICATIONS` | 13+ (API 33) | FGS notification | ❌ Missing |

### Optional Permissions (If Needed)

| Permission | Purpose | When to Add |
|------------|---------|-------------|
| `READ_MEDIA_IMAGES` | Read photos | If browsing gallery |
| `READ_MEDIA_VIDEO` | Read videos | If browsing gallery |
| `VIBRATE` | Haptic feedback | If using vibration |

### Deprecated Permissions (Do NOT Use)

| Permission | Reason |
|------------|--------|
| `READ_EXTERNAL_STORAGE` | Replaced by granular media permissions |
| `WRITE_EXTERNAL_STORAGE` | Blocked on Android 11+ |
| `MANAGE_EXTERNAL_STORAGE` | Play Store restrictions |

---

## Feature Declarations

### Current Features

| Feature | Required Attribute | Assessment |
|---------|-------------------|------------|
| `android.hardware.camera` | `false` | ✅ Correct - USB camera doesn't require built-in camera |
| `android.hardware.usb.host` | `false` | ✅ Correct - App can run on devices without USB host |

### Recommended Features

```xml
<!-- USB host is the primary feature, but not strictly required -->
<uses-feature android:name="android.hardware.usb.host" android:required="false"/>

<!-- Camera feature not required for USB camera -->
<uses-feature android:name="android.hardware.camera" android:required="false"/>

<!-- Consider adding for devices with USB-C OTG -->
<uses-feature android:name="android.software.companion_device_setup" android:required="false"/>
```

---

## Complete Recommended Manifest

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.serenegiant.uvccamera">

    <!-- USB Camera does not require built-in camera -->
    <uses-permission android:name="android.permission.CAMERA" />

    <!-- Foreground Service for USB session persistence (Android 14+) -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>

    <!-- Notification permission for FGS (Android 13+) -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>

    <!-- Features (all optional) -->
    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <uses-feature android:name="android.hardware.usb.host" android:required="false" />

    <application>
        <!-- USB Camera Foreground Service -->
        <service
            android:name=".service.UsbCameraService"
            android:foregroundServiceType="connectedDevice"
            android:exported="false">
        </service>

        <!-- USB Device Attachment Receiver -->
        <receiver
            android:name=".receiver.UsbDeviceReceiver"
            android:exported="true">
            <intent-filter>
                <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"/>
            </intent-filter>
            <meta-data
                android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
                android:resource="@xml/usb_device_filter"/>
        </receiver>
    </application>

</manifest>
```

---

## USB Device Filter (res/xml/usb_device_filter.xml)

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- UVC Video Class (Class 0x0E) -->
    <usb-device class="239" subclass="2" protocol="1" />

    <!-- Specific device filter example -->
    <!--
    <usb-device vendor-id="1234" product-id="5678" />
    -->
</resources>
```

---

## Permission Request Flow

### Runtime Permission Flow (Android 13+)

```kotlin
class UsbCameraActivity : AppCompatActivity() {

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val allGranted = permissions.all { it.value }
        if (allGranted) {
            startUsbCameraService()
        } else {
            showPermissionRationale()
        }
    }

    private fun checkAndRequestPermissions() {
        val required = mutableListOf<String>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(POST_NOTIFICATIONS) != PERMISSION_GRANTED) {
                required.add(POST_NOTIFICATIONS)
            }
        }

        if (required.isEmpty()) {
            startUsbCameraService()
        } else {
            permissionLauncher.launch(required.toTypedArray())
        }
    }
}
```

---

## Manifest Merge Considerations

Since this is a library manifest, consumer apps will merge their manifest with this one.

### Manifest Merge Rules

| Element | Merge Behavior |
|---------|---------------|
| `<uses-permission>` | Combined (union) |
| `<uses-feature>` | Combined, `required=true` wins |
| `<service>` | Must be declared in app manifest |
| `<receiver>` | Must be declared in app manifest |

### Consumer App Requirements

Apps using this library MUST:
1. Declare `FOREGROUND_SERVICE_CONNECTED_DEVICE` permission
2. Declare `POST_NOTIFICATIONS` for Android 13+
3. Implement `UsbCameraService` with `connectedDevice` type
4. Handle notification permission request at runtime

---

## Verification Commands

### Check Merged Manifest

```bash
# Build APK and extract merged manifest
./gradlew :app:assembleDebug
aapt2 dump badging app/build/outputs/apk/debug/app-debug.apk | grep -E "uses-permission|uses-feature"

# Or use Android Studio: Build > Analyze APK > AndroidManifest.xml
```

### Verify Permissions at Runtime

```kotlin
fun verifyPermissions(context: Context) {
    val pm = context.packageManager

    // Check declared permissions
    val packageInfo = pm.getPackageInfo(
        context.packageName,
        PackageManager.GET_PERMISSIONS
    )

    packageInfo.requestedPermissions?.forEach { permission ->
        val granted = context.checkSelfPermission(permission) ==
            PackageManager.PERMISSION_GRANTED
        Log.d("Permissions", "$permission: $granted")
    }
}
```

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-008** | Foreground Service implementation |
| **SECURITY-001** | USB permission flow |
| **AUDIT-004 Appendix A** | Full permission reference |

---

*End of SECURITY-005*
