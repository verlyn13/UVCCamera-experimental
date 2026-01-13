# SECURITY-004: Scoped Storage Compliance Assessment

**Audit:** AUDIT-004 Android Security Compliance
**Generated:** 2026-01-11
**Target:** `/lib/src/main/jni/`

---

## Executive Summary

| Metric | Count | Risk Level |
|--------|-------|------------|
| **Raw `/sdcard/` paths in UVCCamera** | 0 | ✅ COMPLIANT |
| **`fopen()` with hardcoded paths** | 0 in UVCCamera | ✅ COMPLIANT |
| **Third-party library `fopen()`** | 30+ | LOW (isolated) |
| **Native file operations** | Minimal | ✅ COMPLIANT |

**Overall Assessment:** UVCCamera core code is **COMPLIANT** with Scoped Storage requirements. No direct `/sdcard/` access patterns found. File I/O is properly delegated to managed layer.

---

## Raw Path Access Analysis

### Search Results

**Pattern: `/sdcard/` or `/storage/emulated/`**
```bash
grep -rn '/sdcard\|/storage/emulated' $JNI_PATH --include="*.c" --include="*.cpp"
```

**Result:** No matches in UVCCamera core code.

**Pattern: `/mnt/sdcard/`**
```bash
grep -rn '/mnt/sdcard' $JNI_PATH --include="*.c" --include="*.cpp"
```

**Result:** No matches.

---

## fopen() Analysis

### UVCCamera Core Code

**Search:**
```bash
grep -rn 'fopen' $JNI_PATH/UVCCamera --include="*.c" --include="*.cpp"
```

**Result:** No `fopen()` calls with file paths in UVCCamera directory.

### Third-Party Libraries

**libjpeg-turbo:**
```
lib/src/main/jni/libjpeg-turbo-1.5.0/cdjpeg.c:76:  fopen()
lib/src/main/jni/libjpeg-turbo-1.5.0/wrjpgcom.c:...
lib/src/main/jni/libjpeg-turbo-1.5.0/rdjpgcom.c:...
```

**Analysis:** These are in test utilities and command-line tools, not the library core. Not called from UVCCamera.

**rapidjson:**
```
lib/src/main/jni/rapidjson/include/rapidjson/filereadstream.h
lib/src/main/jni/rapidjson/include/rapidjson/filewritestream.h
```

**Analysis:** These are optional file stream wrappers. UVCCamera uses in-memory JSON parsing, not file-based.

---

## Native File Operation Patterns

### FILE* Usage

**Search:**
```bash
grep -rn 'FILE\s*\*' $JNI_PATH/UVCCamera --include="*.c" --include="*.cpp"
```

**Result:** No `FILE*` declarations in UVCCamera core.

### open() Syscall

**Search:**
```bash
grep -rn 'open\s*(' $JNI_PATH/UVCCamera --include="*.c" --include="*.cpp"
```

**Result:** No direct `open()` syscalls for file paths.

---

## Storage Access Architecture

### Current Implementation

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     CURRENT STORAGE ACCESS (COMPLIANT)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Kotlin/Java Layer                                                           │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  Frame Capture:                                                        │ │
│  │    MediaStore.Images.Media.insert() → URI                             │ │
│  │    contentResolver.openOutputStream(uri)                              │ │
│  │                                                                        │ │
│  │  Video Recording:                                                      │ │
│  │    SAF DocumentFile.createFile() → URI                                │ │
│  │    contentResolver.openFileDescriptor(uri, "w")                       │ │
│  │                                                                        │ │
│  │  Configuration:                                                        │ │
│  │    context.filesDir / getExternalFilesDir()  → App-specific storage  │ │
│  │                                                                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  Native Layer                                                                │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  Frame Processing:                                                     │ │
│  │    Receives frame data in memory (AHardwareBuffer)                    │ │
│  │    Does NOT write to storage directly                                 │ │
│  │                                                                        │ │
│  │  JPEG Encoding:                                                        │ │
│  │    Uses memory buffers, not file handles                              │ │
│  │    Returns encoded data to Java for storage                           │ │
│  │                                                                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Pipeline File Access

### SQLiteBufferedPipeline

**Location:** `lib/src/main/jni/UVCCamera/pipeline/SQLiteBufferedPipeline.cpp`

**Pattern:**
```cpp
static ID_TYPE nativeCreate(JNIEnv *env, jobject thiz,
                            jstring database_path, ...)
```

**Analysis:** Accepts database path from Java layer. The path is:
- For app-specific storage: `context.getDatabasePath()`
- Already within Scoped Storage sandbox
- No `/sdcard/` access

---

## Recommended Patterns for Future Development

### Frame Save (If Adding Direct Native Save)

**PROHIBITED:**
```cpp
void saveFrame(const uint8_t* data, size_t size, const char* filename) {
    char path[256];
    snprintf(path, sizeof(path), "/sdcard/DCIM/ScopeCam/%s", filename);
    FILE* f = fopen(path, "wb");  // ❌ WILL FAIL
    fwrite(data, 1, size, f);
    fclose(f);
}
```

**COMPLIANT:**
```cpp
// Native receives FD from Kotlin SAF flow
void saveFrameToFd(const uint8_t* data, size_t size, int fd) {
    write(fd, data, size);  // ✓ FD from framework
}
```

```kotlin
// Kotlin handles SAF
suspend fun saveFrame(data: ByteArray, filename: String) {
    val uri = MediaStore.Images.Media.getContentUri(
        MediaStore.VOLUME_EXTERNAL_PRIMARY
    )
    val values = ContentValues().apply {
        put(MediaStore.Images.Media.DISPLAY_NAME, filename)
        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
        put(MediaStore.Images.Media.RELATIVE_PATH, "DCIM/ScopeCam")
    }
    val imageUri = contentResolver.insert(uri, values)
    contentResolver.openFileDescriptor(imageUri!!, "w")?.use { pfd ->
        nativeSaveFrame(data, pfd.fd)
    }
}
```

---

## Scoped Storage Permission Matrix

| Storage Location | Native Access | Java Access | Permission Required |
|-----------------|---------------|-------------|---------------------|
| `/sdcard/DCIM/` | ❌ Blocked | MediaStore API | READ_MEDIA_IMAGES |
| `/sdcard/Download/` | ❌ Blocked | SAF | User selection |
| `getExternalFilesDir()` | Via FD | Direct | None |
| `getCacheDir()` | Via FD | Direct | None |
| `/data/data/<pkg>/` | Via FD | Direct | None |

---

## Manifest Permission Audit

**Current Manifest:** `lib/src/main/AndroidManifest.xml`
```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-feature android:name="android.hardware.camera" android:required="false" />
<uses-feature android:name="android.hardware.usb.host" android:required="false" />
```

**Storage Permissions Status:**

| Permission | Status | Needed For |
|------------|--------|------------|
| `READ_EXTERNAL_STORAGE` | Not declared | ❌ DEPRECATED |
| `WRITE_EXTERNAL_STORAGE` | Not declared | ❌ DEPRECATED |
| `READ_MEDIA_IMAGES` | Not declared | Photo gallery access |
| `READ_MEDIA_VIDEO` | Not declared | Video gallery access |
| `MANAGE_EXTERNAL_STORAGE` | Not declared | ❌ Avoid (app store restrictions) |

**Recommendation:** If app needs MediaStore access, add:
```xml
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
```

---

## Testing Strategy

### Test 1: Verify No Raw Path Access

```kotlin
@Test
fun testNoRawPathAccess() {
    // This should NOT crash or create files in /sdcard/
    val camera = UVCCamera()
    camera.startCapture()

    // Verify no files created in restricted locations
    val dcimDir = File("/sdcard/DCIM/ScopeCam")
    assertFalse(dcimDir.exists() || dcimDir.listFiles()?.isNotEmpty() == true)
}
```

### Test 2: SAF Flow Works

```kotlin
@Test
fun testSafSaveFrame() {
    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
        type = "image/jpeg"
        putExtra(Intent.EXTRA_TITLE, "test.jpg")
    }
    // Launch SAF picker, get URI
    val uri = launchSafAndGetUri(intent)

    contentResolver.openFileDescriptor(uri, "w")?.use { pfd ->
        val result = nativeSaveFrame(testFrameData, pfd.fd)
        assertEquals(0, result)
    }

    // Verify file was written
    contentResolver.openInputStream(uri)?.use { input ->
        assertTrue(input.available() > 0)
    }
}
```

---

## Cross-Reference

| Document | Relationship |
|----------|--------------|
| **SECURITY-002** | FD injection for storage FDs |
| **SECURITY-005** | Manifest permission declarations |
| **AUDIT-004** | Scoped Storage migration templates |

---

*End of SECURITY-004*
