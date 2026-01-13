/*
 * uvc_build_id.c
 *
 * Build identification for runtime verification.
 * Implements DECISION-017 from ARCH-DECISIONS-001-R2.
 *
 * This file provides a function that returns the build identifier
 * string, allowing scopecam-engine to verify it loaded the correct
 * version of the native library.
 *
 * Copyright (c) 2026 ScopeCam Project
 * Licensed under the Apache License, Version 2.0
 */

#include <stddef.h>

/* Build defines injected by Android.mk:
 * UVC_GIT_SHA       - Git short SHA (e.g., "abc1234")
 * UVC_BUILD_TIME    - ISO timestamp (e.g., "20260112T171800Z")
 * UVC_GIT_DIRTY     - "dirty" if uncommitted changes, empty otherwise
 */

#ifndef UVC_GIT_SHA
#define UVC_GIT_SHA "unknown"
#endif

#ifndef UVC_BUILD_TIME
#define UVC_BUILD_TIME "unknown"
#endif

#ifndef UVC_GIT_DIRTY
#define UVC_GIT_DIRTY ""
#endif

/* Build ID format: "uvccamera-experimental:<sha>[-dirty]@<timestamp>"
 * Example: "uvccamera-experimental:abc1234@20260112T171800Z"
 * Example: "uvccamera-experimental:abc1234-dirty@20260112T171800Z"
 */
static const char build_id[] =
    "uvccamera-experimental:" UVC_GIT_SHA UVC_GIT_DIRTY "@" UVC_BUILD_TIME;

/*
 * uvc_get_build_id - Get the build identification string
 *
 * Returns a pointer to a static string containing the build ID.
 * The string is valid for the lifetime of the library.
 *
 * This function is exported as a C symbol to allow easy lookup
 * via JNI or nm/objdump.
 */
const char* uvc_get_build_id(void) {
    return build_id;
}

/*
 * uvc_get_git_sha - Get just the git SHA portion
 *
 * Returns the short git SHA (7 chars) of the build.
 */
const char* uvc_get_git_sha(void) {
    return UVC_GIT_SHA;
}

/*
 * uvc_get_build_time - Get just the build timestamp
 *
 * Returns the ISO 8601 timestamp of the build.
 */
const char* uvc_get_build_time(void) {
    return UVC_BUILD_TIME;
}
