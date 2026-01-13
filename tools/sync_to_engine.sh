#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# sync_to_engine.sh
#
# Builds uvccamera-experimental and syncs prebuilt .so files
# to scopecam-engine with verification.
#
# Usage:
#   ./tools/sync_to_engine.sh [--clean] [--skip-build] [--dry-run]
#
# Options:
#   --clean       Clean before building
#   --skip-build  Only sync, don't rebuild
#   --dry-run     Show what would be done without doing it
#
# Implements: DECISION-017 (Build ID in JNI Bridge)
# ============================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UVC_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Target engine directory (can be overridden via environment)
ENGINE_ROOT="${ENGINE_ROOT:-$HOME/Development/personal/scopecam-engine}"

# Build configuration
ABIS=("arm64-v8a" "armeabi-v7a")
LIBS=("libuvc.so" "libusb100.so" "libjpeg-turbo1500.so")

# JNI source directory
JNI_DIR="$UVC_REPO_ROOT/lib/src/main"

# Parse arguments
CLEAN=false
SKIP_BUILD=false
DRY_RUN=false

for arg in "$@"; do
    case $arg in
        --clean)
            CLEAN=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown argument: $arg${NC}"
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check ANDROID_NDK_HOME
    if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
        log_error "ANDROID_NDK_HOME is not set"
        log_info "Expected NDK version: 27.0.12077973"
        log_info "Set with: export ANDROID_NDK_HOME=/path/to/ndk/27.0.12077973"
        exit 1
    fi

    if [[ ! -d "$ANDROID_NDK_HOME" ]]; then
        log_error "ANDROID_NDK_HOME directory does not exist: $ANDROID_NDK_HOME"
        exit 1
    fi

    # Check ndk-build exists
    if [[ ! -x "$ANDROID_NDK_HOME/ndk-build" ]]; then
        log_error "ndk-build not found in $ANDROID_NDK_HOME"
        exit 1
    fi

    # Verify NDK version (optional but recommended)
    local ndk_version
    ndk_version=$(cat "$ANDROID_NDK_HOME/source.properties" 2>/dev/null | grep "Pkg.Revision" | cut -d= -f2 | tr -d ' ')
    log_info "NDK version: $ndk_version"

    # Check engine directory exists
    if [[ ! -d "$ENGINE_ROOT" ]]; then
        log_error "Engine directory not found: $ENGINE_ROOT"
        log_info "Set ENGINE_ROOT environment variable to override"
        exit 1
    fi

    # Check JNI directory exists
    if [[ ! -d "$JNI_DIR/jni" ]]; then
        log_error "JNI directory not found: $JNI_DIR/jni"
        exit 1
    fi

    log_success "Prerequisites OK"
}

# Get git info for build ID
get_git_info() {
    cd "$UVC_REPO_ROOT"

    GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    GIT_DIRTY=""
    if ! git diff --quiet HEAD 2>/dev/null; then
        GIT_DIRTY="-dirty"
    fi
    BUILD_TIME=$(date -u +%Y%m%dT%H%M%SZ)

    log_info "Git SHA: $GIT_SHA$GIT_DIRTY"
    log_info "Build time: $BUILD_TIME"
}

# Clean build artifacts
clean_build() {
    log_info "Cleaning build artifacts..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would clean: $JNI_DIR/libs/ $JNI_DIR/obj/"
        return
    fi

    rm -rf "$JNI_DIR/libs" "$JNI_DIR/obj"
    log_success "Clean complete"
}

# Build with ndk-build
build_native() {
    log_info "Building native libraries..."

    cd "$JNI_DIR"

    # Calculate parallel jobs
    local jobs
    if command -v sysctl &>/dev/null; then
        jobs=$(sysctl -n hw.ncpu)
    elif command -v nproc &>/dev/null; then
        jobs=$(nproc)
    else
        jobs=4
    fi

    local build_cmd=(
        "$ANDROID_NDK_HOME/ndk-build"
        "-j$jobs"
        "NDK_PROJECT_PATH=$JNI_DIR"
        "NDK_APPLICATION_MK=$JNI_DIR/jni/Application.mk"
    )

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would run: ${build_cmd[*]}"
        return
    fi

    log_info "Running: ${build_cmd[*]}"

    if ! "${build_cmd[@]}"; then
        log_error "Build failed!"
        exit 1
    fi

    log_success "Build complete"
}

# Compute SHA256 hash of a file
compute_hash() {
    local file="$1"
    if command -v shasum &>/dev/null; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    else
        log_error "No SHA256 utility found"
        exit 1
    fi
}

# Sync libraries to engine
sync_libraries() {
    log_info "Syncing libraries to scopecam-engine..."

    local changes=0
    local unchanged=0
    local skipped=0

    for abi in "${ABIS[@]}"; do
        log_info "Processing ABI: $abi"

        for lib in "${LIBS[@]}"; do
            local src="$JNI_DIR/libs/$abi/$lib"
            local dst="$ENGINE_ROOT/nativecode/src/main/libs/$abi/$lib"

            # Check if source exists
            if [[ ! -f "$src" ]]; then
                log_warn "  $lib: not built (skipping)"
                ((++skipped))
                continue
            fi

            # Compute source hash
            local src_hash
            src_hash=$(compute_hash "$src")

            # Compute destination hash (if exists)
            local dst_hash="(none)"
            if [[ -f "$dst" ]]; then
                dst_hash=$(compute_hash "$dst")
            fi

            # Check if copy needed
            if [[ "$src_hash" == "$dst_hash" ]]; then
                log_info "  $lib: unchanged"
                ((++unchanged))
                continue
            fi

            # Perform copy
            if [[ "$DRY_RUN" == true ]]; then
                log_info "  [DRY RUN] Would copy $lib"
                log_info "    Source: $src_hash"
                log_info "    Dest:   $dst_hash"
            else
                mkdir -p "$(dirname "$dst")"
                cp -f "$src" "$dst"

                # Verify copy
                local new_hash
                new_hash=$(compute_hash "$dst")

                if [[ "$src_hash" != "$new_hash" ]]; then
                    log_error "  $lib: copy verification failed!"
                    log_error "    Expected: $src_hash"
                    log_error "    Got:      $new_hash"
                    exit 1
                fi

                log_success "  $lib: UPDATED"
                log_info "    Old: ${dst_hash:0:16}..."
                log_info "    New: ${new_hash:0:16}..."
            fi

            ((++changes))
        done
    done

    echo ""
    log_info "Sync summary:"
    log_info "  Changed:   $changes"
    log_info "  Unchanged: $unchanged"
    log_info "  Skipped:   $skipped"
}

# Generate manifest with hashes
generate_manifest() {
    log_info "Generating build manifest..."

    local manifest_file="$JNI_DIR/jni/include/uvc_build_manifest.h"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would generate: $manifest_file"
        return
    fi

    mkdir -p "$(dirname "$manifest_file")"

    cat > "$manifest_file" << EOF
// Auto-generated by sync_to_engine.sh
// Do not edit manually

#ifndef UVC_BUILD_MANIFEST_H
#define UVC_BUILD_MANIFEST_H

#define UVC_BUILD_GIT_SHA "$GIT_SHA$GIT_DIRTY"
#define UVC_BUILD_TIMESTAMP "$BUILD_TIME"
EOF

    # Add library hashes
    for abi in "${ABIS[@]}"; do
        local abi_upper
        abi_upper=$(echo "$abi" | tr '[:lower:]-' '[:upper:]_')

        for lib in "${LIBS[@]}"; do
            local src="$JNI_DIR/libs/$abi/$lib"
            if [[ -f "$src" ]]; then
                local hash
                hash=$(compute_hash "$src")
                local lib_upper
                lib_upper=$(echo "${lib%.so}" | tr '[:lower:]-' '[:upper:]_')
                echo "#define UVC_${lib_upper}_${abi_upper}_HASH \"$hash\"" >> "$manifest_file"
            fi
        done
    done

    cat >> "$manifest_file" << EOF

// NDK info
#define UVC_NDK_VERSION "${ANDROID_NDK_HOME##*/}"

#endif // UVC_BUILD_MANIFEST_H
EOF

    log_success "Manifest generated: $manifest_file"
}

# Print verification instructions
print_verification() {
    echo ""
    log_info "============================================"
    log_info "Sync complete!"
    log_info "============================================"
    echo ""
    log_info "To verify:"
    log_info "  1. Build and run scopecam-engine app"
    log_info "  2. Check logcat for build ID:"
    log_info "     adb logcat | grep 'libuvc build'"
    log_info "  3. Expected pattern:"
    log_info "     libuvc build: uvccamera-experimental:$GIT_SHA$GIT_DIRTY@$BUILD_TIME"
    echo ""
}

# Main execution
main() {
    echo ""
    log_info "============================================"
    log_info "uvccamera-experimental → scopecam-engine sync"
    log_info "============================================"
    echo ""

    check_prerequisites
    get_git_info

    if [[ "$CLEAN" == true ]]; then
        clean_build
    fi

    if [[ "$SKIP_BUILD" != true ]]; then
        build_native
    fi

    sync_libraries
    generate_manifest
    print_verification
}

main "$@"
