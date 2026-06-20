#!/usr/bin/env bash

set -euo pipefail

# Global ENV
ROOT_DIR=.
DEBUG=0


for arg in "$@"; do
  case "$arg" in
    -d|--debug)
      DEBUG=1
    ;;
    *)
      ROOT_DIR="$arg"
    ;;
  esac
done

THUMBNAIL_DIR="$ROOT_DIR/thumbnails"
  
# loging
log() {
  [[ "$DEBUG" == "1" ]] && echo "[DEBUG] $*"
}

# start
echo "➡ ROOT_DIR: $ROOT_DIR"

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "❌ ROOT_DIR does not exist:$ROOT_DIR"
  exit 1
fi

mkdir -p "$THUMBNAIL_DIR"
log "thumbnails dir: $THUMBNAIL_DIR"

shopt -s nullglob

dirs=()
for d in "$ROOT_DIR"/*; do
  [[ -d "$d" ]] || continue
  [[ "$(basename "$d")" == "thumbnails" ]] && continue
  dirs+=("$d")
done

if (( ${#dirs[@]} == 0 )); then
  echo "⚠ No files or folders found in ROOT_DIR"
  exit 0
fi

for dir in "${dirs[@]}"; do
  
  log "Checking: $dir"

  # only dirs
  [[ -d "$dir" ]] || continue

  folder_name=$(basename "$dir")

  # pass thumbnails dir
  [[ "$folder_name" == "thumbnails" ]] && continue

  preview_dir="$dir/.preview"

  log "Preview dir: $preview_dir"

  # pass .preview dir if doesn't exist
  [[ -d "$preview_dir" ]] || {
    log "No preview dir in $folder_name"
    continue
  }

  images=(
    "$preview_dir"/*.jpg
    # "$preview_dir"/*.jpeg
    "$preview_dir"/*.png
    # "$preview_dir"/*.webp
  )
  
  if (( ${#images[@]} == 0 )); then
    log "No images found in $preview_dir"
    continue
  fi

  output_file="$THUMBNAIL_DIR/${folder_name}.webp"

  echo "Creating thumbnail: $folder_name (${#images[@]} images)"

  echo "FILES:"
  ls "$preview_dir"

  montage "${images[@]}" \
    -thumbnail 480x270 \
    -tile 2x \
    -geometry +10+10 \
    -background "#1e1e1e" \
    "$output_file"

  echo "✅ Done: $output_file"

done

shopt -u nullglob

echo "All Done!"
