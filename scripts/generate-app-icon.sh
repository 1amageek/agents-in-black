#!/bin/bash
set -euo pipefail

# Generate all macOS app icon sizes from a 1024x1024 source PNG.
# Usage: ./scripts/generate-app-icon.sh path/to/icon-1024.png

SOURCE="${1:?Usage: $0 <source-1024x1024.png>}"
ICONSET_DIR="AgentsInBlack/AgentsInBlack/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SOURCE" ]; then
    echo "Error: File not found: $SOURCE"
    exit 1
fi

# Verify source is at least 1024x1024
WIDTH=$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/{print $2}')
HEIGHT=$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/{print $2}')
if [ "$WIDTH" -lt 1024 ] || [ "$HEIGHT" -lt 1024 ]; then
    echo "Error: Source image must be at least 1024x1024 (got ${WIDTH}x${HEIGHT})"
    exit 1
fi

# size_base scale pixel_size filename
SIZES=(
    "16   1  16   icon_16x16.png"
    "16   2  32   icon_16x16@2x.png"
    "32   1  32   icon_32x32.png"
    "32   2  64   icon_32x32@2x.png"
    "128  1  128  icon_128x128.png"
    "128  2  256  icon_128x128@2x.png"
    "256  1  256  icon_256x256.png"
    "256  2  512  icon_256x256@2x.png"
    "512  1  512  icon_512x512.png"
    "512  2  1024 icon_512x512@2x.png"
)

echo "Generating icons into $ICONSET_DIR ..."

for entry in "${SIZES[@]}"; do
    read -r base scale pixels filename <<< "$entry"
    sips -z "$pixels" "$pixels" "$SOURCE" --out "$ICONSET_DIR/$filename" > /dev/null 2>&1
    echo "  ${pixels}x${pixels} -> $filename"
done

# Write Contents.json
cat > "$ICONSET_DIR/Contents.json" << 'EOF'
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "Done. Contents.json updated."
