#!/usr/bin/env bash
#
# generate_preview.sh — build a contact-sheet style thumbnail (webp) for
# every subfolder of ROOT_DIR that contains a ".preview" folder with images.
#
# Usage:
#   ./generate_preview.sh [ROOT_DIR] [options]
#
# Options:
#   -d, --debug              Enable debug logging
#   -o, --output-dir DIR     Where thumbnails are written (default: ./assets/thumbnails)
#   -t, --tile GEOM          montage -tile geometry, e.g. 2x, 3x, 4x2 (default: 2x)
#   -s, --size WxH           montage -thumbnail size (default: 480x270)
#   -e, --ext "a b c"        Space-separated list of extensions to include
#                             (default: "jpg jpeg png webp")
#   -h, --help                Show this help and exit
#
set -uo pipefail   # no -e: a failure in one folder must not kill the whole run

# ---------- defaults / globals ----------
ROOT_DIR="."
DEBUG=0
THUMBNAIL_DIR="./assets/thumbnails"
TILE="2x"
SIZE="480x270"
EXTENSIONS=("jpg" "jpeg" "png" "webp")
ROOT_DIR_SET=0

OK_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

# ---------- helpers ----------
log() {
  (( DEBUG )) && echo "[DEBUG] $*"
  return 0
}

die() {
  echo "❌ $*" >&2
  exit 1
}

print_help() {
  cat <<EOF
 generate_preview.sh — build a contact-sheet style thumbnail (webp) for
 every subfolder of ROOT_DIR that contains a ".preview" folder with images.

 Usage:
   ./generate_preview.sh [ROOT_DIR] [options]

 Options:
   -d, --debug              Enable debug logging
   -o, --output-dir DIR     Where thumbnails are written (default: ./assets/thumbnails)
   -t, --tile GEOM          montage -tile geometry, e.g. 2x, 3x, 4x2 (default: 2x)
   -s, --size WxH           montage -thumbnail size (default: 480x270)
   -e, --ext "a b c"        Space-separated list of extensions to include
                             (default: "jpg jpeg png webp")
   -h, --help                Show this help and exit
EOF
}

# Make a string safe to use as part of a filename
sanitize() {
  local s="$1"
  s="${s//\//_}"   # slashes -> underscores
  s="${s#.}"       # drop a single leading dot ("./foo" -> "foo")
  s="${s#_}"       # drop leading underscore left behind by the above
  [[ -z "$s" ]] && s="root"
  printf '%s' "$s"
}

#b---------- argument parsing ----------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--debug)
        DEBUG=1
        shift
        ;;
      -o|--output-dir)
        THUMBNAIL_DIR="${2:?missing value for $1}"
        shift 2
        ;;
      -t|--tile)
        TILE="${2:?missing value for $1}"
        shift 2
        ;;
      -s|--size)
        SIZE="${2:?missing value for $1}"
        shift 2
        ;;
      -e|--ext)
        read -r -a EXTENSIONS <<< "${2:?missing value for $1}"
        shift 2
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      -*)
        print_help
        echo
        die "Unknown option: $1"
        ;;
      *)
        if (( ROOT_DIR_SET )); then
          die "Multiple root directories given ('$ROOT_DIR' and '$1'). Only one is allowed."
        fi
        ROOT_DIR="$1"
        ROOT_DIR_SET=1
        shift
        ;;
    esac
  done
}

# ---------- setup / validation ----------
check_dependencies() {
  command -v montage >/dev/null 2>&1 || die "'montage' (ImageMagick) not found. Install ImageMagick first."
}

check_root_dir() {
  echo "➡ ROOT_DIR: $ROOT_DIR"
  [[ -d "$ROOT_DIR" ]] || die "ROOT_DIR does not exist: $ROOT_DIR"
}

prepare_output_dir() {
  mkdir -p "$THUMBNAIL_DIR"
  log "Thumbnails dir: $THUMBNAIL_DIR"
  # Resolve to an absolute path so later exclusion checks are reliable
  THUMBNAIL_DIR_ABS=$(cd "$THUMBNAIL_DIR" && pwd)
}

# ---------- discovery ----------
# Populates the global array `dirs` with candidate subfolders of ROOT_DIR,
# excluding the thumbnails output directory itself.
collect_dirs() {
  dirs=()
  local d
  shopt -s nullglob
  for d in "$ROOT_DIR"/*; do
    [[ -d "$d" ]] || continue
    [[ "$(cd "$d" && pwd)" == "$THUMBNAIL_DIR_ABS" ]] && continue
    dirs+=("$d")
  done
  shopt -u nullglob
}

# Populates the global array `images` with matching files in a .preview dir.
collect_images() {
  local preview_dir="$1"
  images=()
  local ext f
  shopt -s nullglob
  for ext in "${EXTENSIONS[@]}"; do
    for f in "$preview_dir"/*."$ext"; do
      images+=("$f")
    done
  done
  shopt -u nullglob
}

# ---------- per-folder processing ----------
process_folder() {
  local dir="$1"
  local folder_name preview_dir root_subdir output_file

  folder_name=$(basename "$dir")
  preview_dir="$dir/.preview"

  log "Checking: $dir"
  log "Preview dir: $preview_dir"

  if [[ ! -d "$preview_dir" ]]; then
    log "No .preview dir in $folder_name — skipping"
    ((SKIP_COUNT++))
    return
  fi

  collect_images "$preview_dir"
  if (( ${#images[@]} == 0 )); then
    log "No matching images in $preview_dir — skipping"
    ((SKIP_COUNT++))
    return
  fi

  root_subdir="$THUMBNAIL_DIR/$(sanitize "$ROOT_DIR")"
  mkdir -p "$root_subdir"
  output_file="$root_subdir/${folder_name}.webp"

  echo "Creating thumbnail: $folder_name (${#images[@]} images)"
  log "Files: ${images[*]}"

  if montage "${images[@]}" \
      -thumbnail "$SIZE" \
      -tile "$TILE" \
      -geometry +10+10 \
      -background "#1e1e1e" \
      "$output_file"; then
    echo "✅ Done: $output_file"
    ((OK_COUNT++))
  else
    echo "❌ Failed to build thumbnail for $folder_name (continuing with next folder)" >&2
    ((FAIL_COUNT++))
  fi
}

print_summary() {
  echo "----------------------------------------"
  echo "All done! ✅ $OK_COUNT created, ⚠ $SKIP_COUNT skipped, ❌ $FAIL_COUNT failed"
}

# ---------- main ----------
main() {
  parse_args "$@"
  check_dependencies
  check_root_dir
  prepare_output_dir

  collect_dirs
  if (( ${#dirs[@]} == 0 )); then
    echo "⚠ No folders found in $ROOT_DIR"
    exit 0
  fi

  local dir
  for dir in "${dirs[@]}"; do
    process_folder "$dir"
  done

  print_summary
  (( FAIL_COUNT == 0 ))
}

main "$@"
