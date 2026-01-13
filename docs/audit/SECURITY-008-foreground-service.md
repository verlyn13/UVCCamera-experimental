# SECURITY-008: Foreground Service Requirements

**Audit:** AUDIT-004 Android Security Compliance
**Generated:** 2026-01-11
**Target:** Android 14+ (API 34+) USB Session Persistence

---

## Executive Summary

| Requirement | Current Status | Action |
|-------------|---------------|--------|
| **FGS Permission** | ❌ Not declared | Add to manifest |
| **FGS Connected Device Type** | ❌ Not declared | Add permission + type |
| **Notification Permission** | ❌ Not declared | Add for API 33+ |
| **Service Implementation** | ❌ Not present | Create service |

**Overall Assessment:** Foreground Service configuration is **completely missing**. This is **CRITICAL** for Android 14+ USB session persistence.

---

## Why Foreground Service is Required

### Android 14+ Behavior Changes

| Event | Without FGS | With FGS (connectedDevice) |
|-------|-------------|---------------------------|
| Screen locks | USB data pins disabled | USB remains active |
| App backgrounded | Connection dropped after ~30s | Connection persists |
| Doze mode | Process may be killed | Process exempt |
| Advanced Data Protection | Immediate disconnect | Session continues |

### The USB Session Problem

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     WITHOUT FOREGROUND SERVICE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  User opens app                                                              │
│      │                                                                       │
│      ▼                                                                       │
│  USB permission granted, camera working                                      │
│      │                                                                       │
│      │   [30 seconds later, user locks screen]                              │
│      ▼                                                                       │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  Android 16 with ADP: USB data pins DISABLED                           │ │
│  │  Native code: read(usb_fd) returns ENODEV                              │ │
│  │  Camera stream: DEAD                                                   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│      │                                                                       │
│      │   [User unlocks screen]                                              │
│      ▼                                                                       │
│  USB connection gone. User must re-plug device.                             │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                     WITH FOREGROUND SERVICE (connectedDevice)                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  User opens app                                                              │
│      │                                                                       │
│      ▼                                                                       │
│  App starts FGS with type=connectedDevice                                   │
│      │                                                                       │
│      ▼                                                                       │
│  USB permission granted, camera working                                      │
│      │                                                                       │
│      │   [User locks screen]                                                │
│      ▼                                                                       │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  FGS running: USB data pins REMAIN ACTIVE                              │ │
│  │  Camera stream: CONTINUES                                              │ │
│  │  Background recording: WORKS                                           │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│      │                                                                       │
│      │   [User unlocks screen]                                              │
│      ▼                                                                       │
│  Camera still connected, no interruption.                                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Current State Analysis

### Manifest Search

```bash
grep -rn 'startForeground\|ForegroundService\|foregroundServiceType' $JAVA_PATH $KOTLIN_PATH
```

**Result:** No foreground service implementation found.

### Service Declarations

```bash
grep -rn '<service' $MANIFEST_PATH
```

**Result:** No services declared in library manifest.

---

## Required Implementation

### 1. Manifest Permissions

```xml
<!-- Add to AndroidManifest.xml -->

<!-- Base Foreground Service permission (Android 9+) -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>

<!-- Type-specific permission (Android 14+) -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>

<!-- Notification permission for FGS notification (Android 13+) -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

### 2. Service Declaration

```xml
<application>
    <service
        android:name=".service.UsbCameraService"
        android:foregroundServiceType="connectedDevice"
        android:exported="false">
    </service>
</application>
```

### 3. Service Implementation

```kotlin
/**
 * Foreground service for USB camera session persistence.
 *
 * This service type (connectedDevice) is REQUIRED for Android 14+ to maintain
 * USB connections when:
 * - Screen is locked (with Advanced Data Protection)
 * - App is in background
 * - Device enters Doze mode
 */
class UsbCameraService : Service() {

    companion object {
        private const val CHANNEL_ID = "usb_camera_channel"
        private const val NOTIFICATION_ID = 1001
        private const val TAG = "UsbCameraService"

        fun start(context: Context) {
            val intent = Intent(context, UsbCameraService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, UsbCameraService::class.java))
        }
    }

    private lateinit var notificationManager: NotificationManager

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(NotificationManager::class.java)
        createNotificationChannel()
        Log.d(TAG, "Service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "Service started")

        val notification = createNotification()

        // CRITICAL: Must specify foregroundServiceType for Android 14+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.d(TAG, "Service destroyed")
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "USB Camera Connection",
                NotificationManager.IMPORTANCE_LOW  // Low = no sound
            ).apply {
                description = "Maintains USB camera connection when screen is off"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("USB Camera Active")
            .setContentText("Connected to USB camera")
            .setSmallIcon(R.drawable.ic_camera)  // Must provide icon
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pendingIntent)
            .build()
    }
}
```

---

## Integration Pattern

### Start FGS Before USB Access

```kotlin
class UsbCameraManager(private val context: Context) {
    private val usbManager = context.getSystemService(UsbManager::class.java)

    suspend fun openCamera(device: UsbDevice): Result<CameraHandle> {
        // 1. Start FGS FIRST
        UsbCameraService.start(context)

        // 2. Then request permission
        val granted = requestPermission(device)
        if (!granted) {
            UsbCameraService.stop(context)
            return Result.failure(SecurityException("USB permission denied"))
        }

        // 3. Open device
        val connection = usbManager.openDevice(device)
            ?: return Result.failure(IOException("Failed to open device"))

        // 4. Pass FD to native
        val handle = nativeInit(connection.fileDescriptor)

        return Result.success(CameraHandle(handle, connection))
    }

    fun closeCamera(handle: CameraHandle) {
        nativeClose(handle.nativeHandle)
        handle.connection.close()

        // Stop FGS only when all cameras closed
        if (activeCameraCount == 0) {
            UsbCameraService.stop(context)
        }
    }
}
```

### Handle Notification Permission (API 33+)

```kotlin
class CameraActivity : AppCompatActivity() {

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            openUsbCamera()
        } else {
            // Show rationale - FGS notification required for background use
            showNotificationRationale()
        }
    }

    private fun checkNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            when {
                checkSelfPermission(POST_NOTIFICATIONS) == PERMISSION_GRANTED -> {
                    openUsbCamera()
                }
                shouldShowRequestPermissionRationale(POST_NOTIFICATIONS) -> {
                    showNotificationRationale()
                }
                else -> {
                    notificationPermissionLauncher.launch(POST_NOTIFICATIONS)
                }
            }
        } else {
            openUsbCamera()
        }
    }

    private fun showNotificationRationale() {
        AlertDialog.Builder(this)
            .setTitle("Notification Permission Required")
            .setMessage("To keep the camera running when the screen is off, " +
                       "this app needs to show a persistent notification.")
            .setPositiveButton("Grant") { _, _ ->
                notificationPermissionLauncher.launch(POST_NOTIFICATIONS)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }
}
```

---

## Service Lifecycle

### Normal Operation

```
App Launch
    │
    ▼
User connects USB camera
    │
    ▼
startForegroundService() ─────────────────────────────┐
    │                                                  │
    ▼                                                  │
UsbManager.requestPermission()                         │
    │                                                  │
    ▼                                                  │
UsbManager.openDevice() → FD                           │
    │                                                  │
    ▼                                                  │
nativeInit(fd) → Camera streaming                      │
    │                                                  │
    │   [Screen locks]                                 │ FGS keeps
    │                                                  │ USB alive
    ▼                                                  │
Camera continues streaming in background ◄─────────────┘
    │
    │   [User unlocks, closes camera]
    │
    ▼
nativeClose() + connection.close()
    │
    ▼
stopService() ─────────────────────────────────────────┘
```

### Error Recovery

```kotlin
class UsbCameraService : Service() {

    private val usbDisconnectReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED) {
                Log.w(TAG, "USB device detached")
                // Notify camera manager
                EventBus.post(UsbDisconnectedEvent())
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        // Register for USB disconnect events
        registerReceiver(
            usbDisconnectReceiver,
            IntentFilter(UsbManager.ACTION_USB_DEVICE_DETACHED)
        )
    }

    override fun onDestroy() {
        unregisterReceiver(usbDisconnectReceiver)
        super.onDestroy()
    }
}
```

---

## Testing Strategy

### Test 1: FGS Keeps USB Alive

```kotlin
@Test
fun testFgsKeepsUsbAlive() {
    // Start FGS
    UsbCameraService.start(context)

    // Open camera
    val handle = openTestCamera()

    // Simulate screen lock (requires instrumentation)
    deviceController.lockScreen()
    Thread.sleep(5000)

    // Camera should still be streaming
    val status = nativeGetStatus(handle)
    assertEquals(CameraStatus.STREAMING, status)

    // Unlock and cleanup
    deviceController.unlockScreen()
    closeTestCamera(handle)
    UsbCameraService.stop(context)
}
```

### Test 2: Without FGS

```kotlin
@Test
fun testWithoutFgsDisconnects() {
    // Open camera WITHOUT starting FGS
    val handle = openTestCamera()

    // Simulate screen lock
    deviceController.lockScreen()
    Thread.sleep(5000)

    // On Android 14+, camera should have disconnected
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        val status = nativeGetStatus(handle)
        assertEquals(CameraStatus.DISCONNECTED, status)
    }

    // Cleanup
    deviceController.unlockScreen()
}
```

---

## Foreground Service Type Matrix

| Type | Permission | Use Case |
|------|------------|----------|
| `connectedDevice` | `FOREGROUND_SERVICE_CONNECTED_DEVICE` | USB cameras, Bluetooth |
| `camera` | `FOREGROUND_SERVICE_CAMERA` | Built-in camera background |
| `mediaPlayback` | `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Audio/video playback |
| `location` | `FOREGROUND_SERVICE_LOCATION` | GPS tracking |
| `dataSync` | `FOREGROUND_SERVICE_DATA_SYNC` | Background sync |

**For USB Camera:** Use `connectedDevice` type.

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-005** | Manifest permission declarations |
| **SECURITY-002** | FD injection (requires FGS for persistence) |
| **AUDIT-003-appendix-advanced.md** | Android 16 USB FD persistence (Appendix D) |

---

*End of SECURITY-008*
