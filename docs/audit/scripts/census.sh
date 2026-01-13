#!/bin/bash
# census.sh - Generate source file census for AUDIT-001
# Adapted for macOS (uses BSD stat syntax)

JNI_PATH="${1:-/Users/verlyn13/Development/personal/UVCCamera-experimental/lib/src/main/jni}"
OUTPUT="${2:-/Users/verlyn13/Development/personal/UVCCamera-experimental/docs/audit/INVENTORY-002-source-census.csv}"

echo "path,extension,size_bytes,lines,last_modified,encoding,component" > "$OUTPUT"

# Function to classify component based on path
classify_component() {
    local path="$1"
    if [[ "$path" == *"/UVCCamera/"* ]]; then
        if [[ "$path" == *"/pipeline/"* ]]; then
            echo "UVCCamera/pipeline"
        else
            echo "UVCCamera"
        fi
    elif [[ "$path" == *"/libuvc/"* ]]; then
        echo "libuvc"
    elif [[ "$path" == *"/libusb/"* ]]; then
        echo "libusb"
    elif [[ "$path" == *"/libjpeg-turbo"* ]]; then
        if [[ "$path" == *"/simd/"* ]]; then
            echo "libjpeg-turbo/simd"
        else
            echo "libjpeg-turbo"
        fi
    elif [[ "$path" == *"/rapidjson/"* ]]; then
        echo "rapidjson"
    elif [[ "$path" == *"/test/"* ]]; then
        echo "test"
    else
        echo "root"
    fi
}

find "$JNI_PATH" -type f \( \
    -name "*.c" -o -name "*.cpp" -o -name "*.cc" -o \
    -name "*.h" -o -name "*.hpp" -o \
    -name "*.s" -o -name "*.S" -o -name "*.asm" \
\) | while read -r file; do
    ext="${file##*.}"
    size=$(stat -f %z "$file" 2>/dev/null)
    lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    modified=$(stat -f %Sm -t %Y-%m-%d "$file" 2>/dev/null)
    encoding=$(file -b --mime-encoding "$file" 2>/dev/null)
    component=$(classify_component "$file")

    # Make path relative to JNI_PATH
    rel_path="${file#$JNI_PATH/}"

    echo "\"$rel_path\",\"$ext\",\"$size\",\"$lines\",\"$modified\",\"$encoding\",\"$component\"" >> "$OUTPUT"
done

echo "Census written to $OUTPUT"
echo "Total files: $(tail -n +2 "$OUTPUT" | wc -l)"
