#!/usr/bin/env bash
# ============================================================
# sync_to_engine.sh - DEPRECATED
#
# This script previously synced prebuilt .so files to scopecam-engine.
# This approach has been deprecated in favor of source-based vendoring.
#
# scopecam-engine now:
# - Vendors libuvc/libusb/libjpeg-turbo SOURCE in third_party/
# - Builds everything from source with CMake
# - Applies patches from uvccamera-experimental as needed
#
# To promote changes from uvccamera-experimental:
# 1. Create a patch file: git format-patch or git diff
# 2. Document the change in docs/
# 3. Submit to scopecam-engine for review
#
# See docs/PROMOTION_WORKFLOW.md for details.
# ============================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo ""
echo -e "${RED}============================================================${NC}"
echo -e "${RED}ERROR: This script is DEPRECATED${NC}"
echo -e "${RED}============================================================${NC}"
echo ""
echo -e "${YELLOW}scopecam-engine no longer consumes prebuilt binaries.${NC}"
echo -e "${YELLOW}It vendors source and builds from scratch.${NC}"
echo ""
echo "The correct workflow is now patch-based promotion:"
echo ""
echo "  1. Make and test changes in uvccamera-experimental"
echo ""
echo "  2. Create a patch file:"
echo "     cd lib/src/main/jni/libuvc"
echo "     git diff > my-feature.patch"
echo ""
echo "  3. Document your changes"
echo ""
echo "  4. Submit patch to scopecam-engine for review"
echo ""
echo "See docs/PROMOTION_WORKFLOW.md for the complete workflow."
echo ""
echo -e "${RED}============================================================${NC}"
exit 1
