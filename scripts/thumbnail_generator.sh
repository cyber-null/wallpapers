#!/usr/bin/env bash
#
# generate-thumbnails.sh
#
# PURPOSE
#   Recursively scan a directory tree for image files and maintain a
#   parallel set of WebP thumbnails, one ".thumbnails" directory per
#   directory that contains images. The script is idempotent: it only
#   (re)generates thumbnails that are missing or stale, and it removes
#   thumbnails whose source image no longer exists.
#
#   This script has exactly one job: thumbnail generation/maintenance.
#   It never touches README/Markdown/HTML files, never touches Git
#   internals, and never modifies, moves, or deletes original images.
#
# REQUIREMENTS
#   One of the following must be installed and on PATH:
#     - ImageMagick (the "magick" command, ImageMagick v7+)
#     - FFmpeg (the "ffmpeg" command)
#   Detection order: magick, then ffmpeg.
#
# USAGE
#   ./generate-thumbnails.sh [OPTIONS]
#   Run with --help for full usage information.
#
set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# GLOBAL CONSTANTS / DEFAULTS
# ---------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly THUMB_DIRNAME=".thumbnails"
readonly THUMB_EXT="webp"

ROOT_DIR="."
THUMB_WIDTH=300
THUMB_QUALITY=85
EXTENSIONS_CSV="jpg,jpeg,png,webp,gif,bmp,avif"

FORCE=0
DRY_RUN=0
VERBOSE=0
DEBUG=0
QUIET=0

# Populated after argument parsing / validation.
declare -a EXT_ARR=()
TOOL=""

# Counters for the final summary.
COUNT_CREATED=0
COUNT_UPDATED=0
COUNT_SKIPPED=0
COUNT_REMOVED=0
COUNT_ERRORS=0

# Tracks temp files currently being written, so cleanup() can remove
# partially-written output if the script is interrupted mid-write.
declare -a TMP_FILES_IN_FLIGHT=()

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
# Log levels (lowest to highest verbosity): quiet < normal < verbose < debug.
# Errors and warnings are always shown, even in quiet mode.

log_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

log_warn() {
    printf 'WARN:  %s\n' "$*" >&2
}

log_info() {
    (( QUIET )) && return 0
    printf '%s\n' "$*"
}

log_verbose() {
    (( QUIET )) && return 0
    if (( VERBOSE )) || (( DEBUG )); then
        printf 'VERBOSE: %s\n' "$*"
    fi
}

log_debug() {
    (( QUIET )) && return 0
    if (( DEBUG )); then
        printf 'DEBUG: %s\n' "$*"
    fi
}

# ---------------------------------------------------------------------------
# CLEANUP / TRAPS
# ---------------------------------------------------------------------------
# Ensures no half-written thumbnail files are left behind if the script
# exits unexpectedly (error, Ctrl-C, kill, etc).

cleanup() {
    local exit_code=$?
    local f
    for f in "${TMP_FILES_IN_FLIGHT[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f -- "$f"
    done
    exit "$exit_code"
}

on_error() {
    local line_no=$1
    log_error "Unexpected failure at line ${line_no}. Aborting."
}

trap cleanup EXIT
trap 'on_error $LINENO' ERR
trap 'log_warn "Interrupted."; exit 130' INT TERM

# ---------------------------------------------------------------------------
# USAGE / HELP
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
${SCRIPT_NAME} - generate and maintain WebP thumbnails for a directory tree

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

DESCRIPTION:
    Recursively scans ROOT_DIR for image files and maintains a
    ".thumbnails" directory alongside every directory that contains
    images. Thumbnails are always written as WebP, resized by width
    only (aspect ratio preserved, never stretched). The script is
    idempotent: unchanged images are skipped, stale/missing thumbnails
    are (re)generated, and thumbnails for deleted originals are removed.

OPTIONS:
    --root PATH          Root directory to scan (default: .)
    --width NUMBER        Thumbnail width in pixels (default: 300)
    --quality NUMBER      WebP compression quality, 0-100 (default: 85)
    --extensions LIST      Comma-separated list of source extensions
                          (default: jpg,jpeg,png,webp,gif,bmp,avif)
    --force               Regenerate every thumbnail, ignoring timestamps
    --dry-run             Show what would be done; write nothing
    --verbose              Verbose logging
    --debug                Very detailed debug logging
    --quiet                Suppress normal informational logging
    --help                 Show this help page and exit

EXAMPLES:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} --root ./assets --width 400 --quality 90
    ${SCRIPT_NAME} --extensions jpg,png --dry-run --verbose
    ${SCRIPT_NAME} --force --quiet

NOTES:
    - Thumbnail directories (".thumbnails") are never scanned recursively.
    - ".git" directories are always skipped.
    - This script never modifies, renames, or deletes original images,
      and never generates README/Markdown/HTML content.
EOF
}

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------

parse_args() {
    while (( "$#" )); do
        case "$1" in
            --root)
                [[ $# -ge 2 ]] || { log_error "--root requires a value"; exit 2; }
                ROOT_DIR="$2"; shift 2 ;;
            --root=*)
                ROOT_DIR="${1#*=}"; shift ;;
            --width)
                [[ $# -ge 2 ]] || { log_error "--width requires a value"; exit 2; }
                THUMB_WIDTH="$2"; shift 2 ;;
            --width=*)
                THUMB_WIDTH="${1#*=}"; shift ;;
            --quality)
                [[ $# -ge 2 ]] || { log_error "--quality requires a value"; exit 2; }
                THUMB_QUALITY="$2"; shift 2 ;;
            --quality=*)
                THUMB_QUALITY="${1#*=}"; shift ;;
            --extensions)
                [[ $# -ge 2 ]] || { log_error "--extensions requires a value"; exit 2; }
                EXTENSIONS_CSV="$2"; shift 2 ;;
            --extensions=*)
                EXTENSIONS_CSV="${1#*=}"; shift ;;
            --force)
                FORCE=1; shift ;;
            --dry-run)
                DRY_RUN=1; shift ;;
            --verbose)
                VERBOSE=1; shift ;;
            --debug)
                DEBUG=1; shift ;;
            --quiet)
                QUIET=1; shift ;;
            --help|-h)
                usage; exit 0 ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# VALIDATION
# ---------------------------------------------------------------------------

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

validate_args() {
    if [[ ! -d "$ROOT_DIR" ]]; then
        log_error "Root directory does not exist or is not a directory: ${ROOT_DIR}"
        exit 1
    fi
    if [[ ! -r "$ROOT_DIR" ]]; then
        log_error "Root directory is not readable: ${ROOT_DIR}"
        exit 1
    fi

    if ! is_positive_integer "$THUMB_WIDTH"; then
        log_error "--width must be a positive integer, got: ${THUMB_WIDTH}"
        exit 2
    fi

    if [[ ! "$THUMB_QUALITY" =~ ^[0-9]+$ ]] || (( 10#$THUMB_QUALITY > 100 )); then
        log_error "--quality must be an integer between 0 and 100, got: ${THUMB_QUALITY}"
        exit 2
    fi

    if [[ -z "$EXTENSIONS_CSV" ]]; then
        log_error "--extensions cannot be empty"
        exit 2
    fi

    # Split CSV into an array, trimming whitespace and lowercasing.
    IFS=',' read -r -a EXT_ARR <<< "$EXTENSIONS_CSV"
    local i
    for i in "${!EXT_ARR[@]}"; do
        EXT_ARR[$i]="$(printf '%s' "${EXT_ARR[$i]}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        if [[ -z "${EXT_ARR[$i]}" ]]; then
            log_error "Empty extension found in --extensions list"
            exit 2
        fi
    done

    # Normalize ROOT_DIR (strip trailing slash, except for "/").
    if [[ "$ROOT_DIR" != "/" ]]; then
        ROOT_DIR="${ROOT_DIR%/}"
    fi
}

# ---------------------------------------------------------------------------
# TOOL DETECTION
# ---------------------------------------------------------------------------

detect_tool() {
    if command -v magick >/dev/null 2>&1; then
        TOOL="magick"
        log_verbose "Using ImageMagick (magick) for thumbnail generation."
    elif command -v ffmpeg >/dev/null 2>&1; then
        TOOL="ffmpeg"
        log_verbose "Using FFmpeg for thumbnail generation."
    else
        log_error "Neither 'magick' (ImageMagick) nor 'ffmpeg' was found on PATH."
        log_error "Install one of these tools and try again."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

# Builds a find(1) expression (as an array) matching any configured
# extension, case-insensitively.
build_extension_predicate() {
    local -n out_arr=$1
    out_arr=()
    local ext
    local first=1
    for ext in "${EXT_ARR[@]}"; do
        if (( ! first )); then
            out_arr+=( -o )
        fi
        out_arr+=( -iname "*.${ext}" )
        first=0
    done
}

# Returns 0 (true) if a thumbnail's base name has a matching original
# image somewhere in $1 (the source directory) with any configured
# extension. Used for stale-thumbnail detection.
original_exists_for_base() {
    local src_dir="$1" base="$2"
    local ext
    for ext in "${EXT_ARR[@]}"; do
        shopt -s nocaseglob nullglob
        local matches=( "${src_dir}/${base}.${ext}" )
        shopt -u nocaseglob nullglob
        if [[ -e "${matches[0]:-}" ]]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# THUMBNAIL GENERATION
# ---------------------------------------------------------------------------

# generate_thumbnail SRC DST
# Writes to a temp file first, then atomically renames it into place, so
# a crash mid-conversion never leaves a corrupt/partial thumbnail.
generate_thumbnail() {
    local src="$1" dst="$2"
    local tmp="${dst}.tmp.$$.${RANDOM}"

    TMP_FILES_IN_FLIGHT+=( "$tmp" )

    case "$TOOL" in
        magick)
            if ! magick "$src" -auto-orient -resize "${THUMB_WIDTH}x" \
                    -quality "$THUMB_QUALITY" "webp:${tmp}" 2>/dev/null; then
                rm -f -- "$tmp"
                return 1
            fi
            ;;
        ffmpeg)
            if ! ffmpeg -y -loglevel error -i "$src" \
                    -vf "scale=${THUMB_WIDTH}:-1" \
                    -quality "$THUMB_QUALITY" \
                    -f webp "$tmp" </dev/null 2>/dev/null; then
                rm -f -- "$tmp"
                return 1
            fi
            ;;
        *)
            log_error "Internal error: no tool selected."
            return 1
            ;;
    esac

    mv -f -- "$tmp" "$dst"

    # Successfully placed; no longer "in flight" for crash cleanup.
    local i
    for i in "${!TMP_FILES_IN_FLIGHT[@]}"; do
        [[ "${TMP_FILES_IN_FLIGHT[$i]}" == "$tmp" ]] && unset 'TMP_FILES_IN_FLIGHT[i]'
    done

    return 0
}

# process_image SRC_FILE
# Decides whether SRC_FILE's thumbnail needs to be created, updated, or
# skipped, and acts accordingly.
process_image() {
    local src="$1"
    local src_dir base thumb_dir dst

    src_dir="$(dirname -- "$src")"
    base="$(basename -- "$src")"
    base="${base%.*}"
    thumb_dir="${src_dir}/${THUMB_DIRNAME}"
    dst="${thumb_dir}/${base}.${THUMB_EXT}"

    if [[ ! -d "$thumb_dir" ]]; then
        if (( DRY_RUN )); then
            log_verbose "[dry-run] Would create directory: ${thumb_dir}"
        else
            mkdir -p -- "$thumb_dir"
        fi
    fi

    local action=""
    if [[ ! -e "$dst" ]]; then
        action="create"
    elif (( FORCE )); then
        action="update"
    elif [[ "$src" -nt "$dst" ]]; then
        action="update"
    else
        action="skip"
    fi

    case "$action" in
        create)
            if (( DRY_RUN )); then
                log_info "[dry-run] CREATE: ${dst}"
            else
                if generate_thumbnail "$src" "$dst"; then
                    log_info "Thumbnail created: ${dst}"
                else
                    log_error "Failed to create thumbnail for: ${src}"
                    (( ++COUNT_ERRORS ))
                    return
                fi
            fi
            (( ++COUNT_CREATED ))
            ;;
        update)
            if (( DRY_RUN )); then
                log_info "[dry-run] UPDATE: ${dst}"
            else
                if generate_thumbnail "$src" "$dst"; then
                    log_info "Thumbnail updated: ${dst}"
                else
                    log_error "Failed to update thumbnail for: ${src}"
                    (( ++COUNT_ERRORS ))
                    return
                fi
            fi
            (( ++COUNT_UPDATED ))
            ;;
        skip)
            log_debug "Thumbnail skipped (up to date): ${dst}"
            (( ++COUNT_SKIPPED ))
            ;;
    esac
}

# ---------------------------------------------------------------------------
# DISCOVERY
# ---------------------------------------------------------------------------

# Recursively find all source images under ROOT_DIR, excluding
# .thumbnails/ and .git/ directories, and process each one.
scan_and_process_images() {
    local -a ext_predicate=()
    build_extension_predicate ext_predicate

    log_verbose "Scanning ${ROOT_DIR} for images with extensions: ${EXT_ARR[*]}"

    local file
    while IFS= read -r -d '' file; do
        process_image "$file"
    done < <(find "$ROOT_DIR" \
                \( -type d \( -name "$THUMB_DIRNAME" -o -name ".git" \) -prune \) \
                -o \
                \( -type f \( "${ext_predicate[@]}" \) -print0 \) )
}

# Recursively find every .thumbnails directory and remove any thumbnail
# whose corresponding original image no longer exists.
remove_stale_thumbnails() {
    log_verbose "Checking for stale thumbnails under ${ROOT_DIR}"

    local thumb_dir
    while IFS= read -r -d '' thumb_dir; do
        local src_dir="${thumb_dir%/${THUMB_DIRNAME}}"
        local thumb_file
        while IFS= read -r -d '' thumb_file; do
            local base
            base="$(basename -- "$thumb_file")"
            base="${base%.*}"

            if ! original_exists_for_base "$src_dir" "$base"; then
                if (( DRY_RUN )); then
                    log_info "[dry-run] REMOVE (stale): ${thumb_file}"
                else
                    if rm -f -- "$thumb_file"; then
                        log_info "Thumbnail removed (stale): ${thumb_file}"
                    else
                        log_error "Failed to remove stale thumbnail: ${thumb_file}"
                        (( ++COUNT_ERRORS ))
                        continue
                    fi
                fi
                (( ++COUNT_REMOVED ))
            fi
        done < <(find "$thumb_dir" -maxdepth 1 -type f -iname "*.${THUMB_EXT}" -print0)
    done < <(find "$ROOT_DIR" \
                \( -type d -name ".git" -prune \) \
                -o \
                \( -type d -name "$THUMB_DIRNAME" -print0 \) )
}

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------

print_summary() {
    (( QUIET )) && return 0
    echo "---------------------------------------------"
    echo "Thumbnail run summary:"
    echo "  Created: ${COUNT_CREATED}"
    echo "  Updated: ${COUNT_UPDATED}"
    echo "  Skipped: ${COUNT_SKIPPED}"
    echo "  Removed: ${COUNT_REMOVED}"
    echo "  Errors:  ${COUNT_ERRORS}"
    (( DRY_RUN )) && echo "  (dry-run: no files were written or removed)"
    echo "---------------------------------------------"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    validate_args
    detect_tool

    log_verbose "Root:      ${ROOT_DIR}"
    log_verbose "Width:     ${THUMB_WIDTH}"
    log_verbose "Quality:   ${THUMB_QUALITY}"
    log_verbose "Extensions:${EXT_ARR[*]}"
    log_verbose "Force:     ${FORCE}"
    log_verbose "Dry-run:   ${DRY_RUN}"

    scan_and_process_images
    remove_stale_thumbnails
    print_summary

    if (( COUNT_ERRORS > 0 )); then
        exit 1
    fi
}

main "$@"
