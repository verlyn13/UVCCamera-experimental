/*
 * OutputMode.h - Single Source of Truth for Frame Routing
 *
 * Copyright (c) 2026 ScopeCam Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef SCOPECAM_OUTPUT_MODE_H
#define SCOPECAM_OUTPUT_MODE_H

#include <cstdint>

namespace scopecam {

/**
 * Explicit frame output mode for the camera engine.
 *
 * This enum serves as the Single Source of Truth for frame routing decisions,
 * replacing the previous implicit routing based on boolean flags
 * (mSurfaceReady, mUseRingBuffer, mRingBufferInjected).
 *
 * ARCHITECTURAL PRINCIPLE:
 * - OutputMode controls WHERE frames go (routing decision)
 * - PreviewState controls WHETHER threads are running (lifecycle)
 * - These are orthogonal concerns that should not be conflated
 *
 * BROADCASTER PATTERN:
 * Capture callbacks are emitted BEFORE the routing decision.
 * This ensures capture works in ALL modes, including IDLE.
 */
enum class OutputMode : int32_t {
    /**
     * IDLE (Active Drain / WARM State):
     * - USB isochronous transfers remain active (frames captured)
     * - Frames converted and passed to capture callback
     * - Display frames discarded after capture callback (cancelWriteBuffer)
     * - Used when navigating away from preview (e.g., Gallery screen)
     * - Enables instant resume: no USB re-permission needed on return
     *
     * Key insight: The camera stays "warm" - USB streaming continues,
     * we just don't render to display.
     */
    IDLE = 0,

    /**
     * DIRECT_WINDOW (Legacy/Fallback):
     * - Zero-copy write directly to ANativeWindow
     * - Used when ring buffer is not available or disabled
     * - Lower latency but no GPU integration
     * - Will be deprecated in favor of RING_BUFFER mode
     */
    DIRECT_WINDOW = 1,

    /**
     * RING_BUFFER (Modern/Primary):
     * - Zero-copy write to AHardwareBuffer ring
     * - Enables GPU rendering with EGL/GLES integration
     * - Supports Broadcaster pattern (Display + Capture simultaneously)
     * - Fence synchronization for tear-free rendering
     * - This is the recommended production path
     */
    RING_BUFFER = 2
};

/**
 * Converts OutputMode to human-readable string for logging.
 *
 * Thread-safe: No state, pure function.
 */
inline const char* outputModeToString(OutputMode mode) {
    switch (mode) {
        case OutputMode::IDLE:          return "IDLE";
        case OutputMode::DIRECT_WINDOW: return "DIRECT_WINDOW";
        case OutputMode::RING_BUFFER:   return "RING_BUFFER";
        default:                        return "UNKNOWN";
    }
}

/**
 * Validates if an integer value is a valid OutputMode.
 *
 * Use this when receiving mode from JNI to prevent invalid casts.
 */
inline bool isValidOutputMode(int32_t value) {
    return value >= 0 && value <= 2;
}

/**
 * Safe cast from integer to OutputMode with validation.
 *
 * @param value Integer value from JNI
 * @param outMode Pointer to receive the mode
 * @return true if valid, false if invalid (outMode unchanged)
 */
inline bool toOutputMode(int32_t value, OutputMode* outMode) {
    if (!isValidOutputMode(value)) {
        return false;
    }
    *outMode = static_cast<OutputMode>(value);
    return true;
}

} // namespace scopecam

#endif // SCOPECAM_OUTPUT_MODE_H
