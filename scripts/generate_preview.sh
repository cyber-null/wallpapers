#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="${1:-.}"
THUMBNAIL_DIR="$ROOT_DIR/thumbnails"

# debug
echo "ROOT_DIR: $ROOT_DIR"
echo "$ROOT_DIR/*"

mkdir -p "$THUMBNAIL_DIR"

for dir in "$ROOT_DIR"/*; do
  # only dirs
  [[ -d "$dir" ]] || continue

  folder_name=$(basename "$dir")

  # pass thumbnails dir
  [[ "$folder_name" == "thumbnails" ]] || continue

  preview_dir="$dir/.preview"

  # pass .preview dir if doesn't exist
  [[ -d "$preview_dir" ]] || continue

  shopt -s nullglob

  images=(
    "$preview_dir"/*.jpg"
    "$preview_dir"/*.jpeg"
    "$preview_dir"/*.png"
    "$preview_dir"/*.webp"
  )

  shopt -u nullglob
  
  # debug
  echo "DIR: $preview_dir"
  echo "IMAGES: ${images[*]}"

  
  # if doesn't exist, pass it
  (( ${#images[@]} )) || continue

  montage "${images[@]}" \
    -thumbnail 480x270 \
    -tile 2x \
    -geometry +10+10 \
    -background "#1e1e1e" \
    "$THUMBNAIL_DIR/${folder_name}.webp"

  echo "${folder_name} ✅️"

done

echo "Done!"
