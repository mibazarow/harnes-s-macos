#!/bin/sh
# Rebuild AppIcon.appiconset from Resources/AppIconSource.png.
# The artwork is placed on Apple's macOS icon grid: 824x824 content in a 1024 canvas
# with 100 px margins and a 185 px corner radius.
set -e
cd "$(dirname "$0")/.."

SRC=Resources/AppIconSource.png
OUT=Resources/Assets.xcassets/AppIcon.appiconset

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

magick -size 1024x1024 xc:none -fill white \
  -draw "roundrectangle 100,100 924,924 185,185" "$tmp/mask.png"
magick "$SRC" -filter Lanczos -resize 824x824 \
  -background none -gravity center -extent 1024x1024 "$tmp/base.png"
magick "$tmp/base.png" "$tmp/mask.png" -alpha Set -compose DstIn -composite "$tmp/master.png"

for size in 16 32 64 128 256 512 1024; do
  magick "$tmp/master.png" -filter Lanczos -resize "${size}x${size}" "$tmp/icon-$size.png"
done

cp "$tmp/icon-16.png"   "$OUT/icon_16x16.png"
cp "$tmp/icon-32.png"   "$OUT/icon_16x16@2x.png"
cp "$tmp/icon-32.png"   "$OUT/icon_32x32.png"
cp "$tmp/icon-64.png"   "$OUT/icon_32x32@2x.png"
cp "$tmp/icon-128.png"  "$OUT/icon_128x128.png"
cp "$tmp/icon-256.png"  "$OUT/icon_128x128@2x.png"
cp "$tmp/icon-256.png"  "$OUT/icon_256x256.png"
cp "$tmp/icon-512.png"  "$OUT/icon_256x256@2x.png"
cp "$tmp/icon-512.png"  "$OUT/icon_512x512.png"
cp "$tmp/icon-1024.png" "$OUT/icon_512x512@2x.png"

echo "icons rebuilt in $OUT"
