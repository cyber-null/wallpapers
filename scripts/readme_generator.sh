#!/usr/bin/env bash
#
# update-readme-previews.sh
#
# Recursively scans a repository and regenerates the image-gallery "Preview"
# section of every README.md file (except the repository root README.md),
# based on the images found in that README's own directory.
#
# Each gallery cell links to the full-size original image. If a matching
# thumbnail exists in a ".thumbnails/" subdirectory (same basename, ".webp"),
# it is displayed instead of the original to keep the README lightweight.
# Thumbnails are only ever consumed here, never generated, resized, or
# otherwise modified by this script.
#
# Author: (generated for production use)
# License: MIT
#
# -----------------------------------------------------------------------------
# Design summary
# -----------------------------------------------------------------------------
#   * Strict mode + traps guarantee we fail loudly and never leave partial
#     writes behind.
#   * All file discovery uses `find ... -print0` / `read -r -d ''` so that
#     filenames containing spaces, newlines, or glob characters are handled
#     safely.
#   * Every README update is written to a temp file in the SAME directory and
#     then swapped in with `mv -f`, which is an atomic operation on the same
#     filesystem. The original file is only ever replaced in one step.
#   * Only text between the `<!-- PREVIEW_START -->` / `<!-- PREVIEW_END -->`
#     markers is ever touched; everything else in the README is preserved
#     byte-for-byte.
#   * ".git" and ".thumbnails" directories are pruned during traversal: never
#     scanned for README.md files, and never descended into for images.
#
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Defaults / global configuration (overridable via CLI flags)
# -----------------------------------------------------------------------------
ROOT_DIR="."
COLUMNS=3
WIDTH=250
EXTENSIONS="jpg,jpeg,png,webp,gif,svg,bmp,avif"
DRY_RUN=0
FORCE=0
QUIET=0
VERBOSE=0
DEBUG=0

readonly MARKER_START="<!-- PREVIEW_START -->"
readonly MARKER_END="<!-- PREVIEW_END -->"
readonly SCRIPT_NAME="${0##*/}"

# Thumbnails, when present, live in a sibling ".thumbnails/" directory using
# the same basename as the original image with a ".webp" extension, e.g.
# "girl.jpg" -> ".thumbnails/girl.webp". This is fixed by convention (it's how
# the separate thumbnail-generation tool names its output) rather than
# user-configurable.
readonly THUMBNAIL_DIR_NAME=".thumbnails"
readonly THUMBNAIL_EXT="webp"

# Track temp files so cleanup() can remove any that were never mv'd into place
# (e.g. because the script died mid-write).
declare -a TMP_FILES=()

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

log() {
    # Normal, user-facing output. Suppressed by --quiet.
    (( QUIET )) && return 0
    printf '%s\n' "$*"
}

vlog() {
    # Verbose output (processed directories, etc.). Shown by --verbose or --debug.
    (( VERBOSE || DEBUG )) || return 0
    printf '%s\n' "$*"
}

debug() {
    # Debug output. Only shown with --debug. Always goes to stderr so it never
    # pollutes anything a caller might be capturing from stdout.
    (( DEBUG )) || return 0
    printf 'DEBUG: %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# Cleanup / traps
# -----------------------------------------------------------------------------
cleanup() {
    # Disarm the ERR trap first: cleanup runs as the EXIT handler, and any
    # falsy test inside it (e.g. an empty TMP_FILES array) must never be
    # mistaken for a script failure.
    trap - ERR
    local f
    for f in "${TMP_FILES[@]:-}"; do
        if [[ -n "${f:-}" && -f "$f" ]]; then
            rm -f -- "$f"
        fi
    done
    return 0
}
trap cleanup EXIT

on_error() {
    local line="$1"
    die "Unexpected failure at line ${line}. No README files were left partially written."
}
trap 'on_error "$LINENO"' ERR

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
show_help() {
    cat <<EOF
${SCRIPT_NAME} - Regenerate README.md image preview galleries

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

DESCRIPTION:
    Recursively scans --root for README.md files (the README.md located
    directly in --root itself is always ignored; ".git" and ".thumbnails"
    directories are never scanned). For every other README.md found, the
    script looks at the images sitting in that same directory, builds a
    Markdown/HTML image gallery, and writes it between the
    ${MARKER_START} / ${MARKER_END} markers in that README. Everything
    outside the markers is left untouched. If the markers are missing, the
    script offers to add a new "## Preview" section automatically.

    Each gallery cell links to the full-size original image. If a matching
    thumbnail exists at "<dir>/${THUMBNAIL_DIR_NAME}/<name>.${THUMBNAIL_EXT}",
    it is displayed instead of the original; otherwise the original is used
    directly. This script never generates, resizes, or deletes thumbnails —
    it only looks for ones that already exist.

OPTIONS:
    -h, --help                Show this help message and exit.
    -d, --debug               Verbose debug output (paths, counts, tables, timing).
    -v, --verbose             Print each directory as it is processed.
    -c, --columns N           Number of gallery columns (default: ${COLUMNS}).
    -w, --width PX            Image width in pixels (default: ${WIDTH}).
    -e, --extensions LIST     Comma-separated list of image extensions
                               (default: ${EXTENSIONS}).
    -r, --root PATH           Repository root to scan (default: ${ROOT_DIR}).
    -n, --dry-run             Show what would change without writing files.
    -f, --force               Create missing markers / overwrite without
                               interactive confirmation.
    -q, --quiet                Suppress normal output (errors still shown).

EXAMPLES:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} --root ./docs --columns 4 --width 200
    ${SCRIPT_NAME} -e jpg,png,gif --dry-run
    ${SCRIPT_NAME} --debug --verbose
EOF
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--debug)
                DEBUG=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -f|--force)
                FORCE=1
                shift
                ;;
            -q|--quiet)
                QUIET=1
                shift
                ;;
            -c|--columns)
                [[ $# -ge 2 ]] || die "Option $1 requires an argument."
                COLUMNS="$2"
                shift 2
                ;;
            --columns=*)
                COLUMNS="${1#*=}"
                shift
                ;;
            -w|--width)
                [[ $# -ge 2 ]] || die "Option $1 requires an argument."
                WIDTH="$2"
                shift 2
                ;;
            --width=*)
                WIDTH="${1#*=}"
                shift
                ;;
            -e|--extensions)
                [[ $# -ge 2 ]] || die "Option $1 requires an argument."
                EXTENSIONS="$2"
                shift 2
                ;;
            --extensions=*)
                EXTENSIONS="${1#*=}"
                shift
                ;;
            -r|--root)
                [[ $# -ge 2 ]] || die "Option $1 requires an argument."
                ROOT_DIR="$2"
                shift 2
                ;;
            --root=*)
                ROOT_DIR="${1#*=}"
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "Unknown option: $1 (see --help)"
                ;;
            *)
                die "Unexpected positional argument: $1 (see --help)"
                ;;
        esac
    done
}

validate_args() {
    [[ "$COLUMNS" =~ ^[0-9]+$ ]] || die "Invalid --columns value: '${COLUMNS}' (must be a positive integer)"
    (( COLUMNS > 0 )) || die "--columns must be greater than 0"

    [[ "$WIDTH" =~ ^[0-9]+$ ]] || die "Invalid --width value: '${WIDTH}' (must be a positive integer)"
    (( WIDTH > 0 )) || die "--width must be greater than 0"

    [[ -n "$EXTENSIONS" ]] || die "--extensions cannot be empty"

    [[ -d "$ROOT_DIR" ]] || die "Root directory does not exist or is not a directory: ${ROOT_DIR}"
    [[ -r "$ROOT_DIR" ]] || die "Root directory is not readable: ${ROOT_DIR}"
}

# -----------------------------------------------------------------------------
# Discovery
# -----------------------------------------------------------------------------

# Print, NUL-delimited, every README.md under ROOT_DIR except the one
# directly inside ROOT_DIR itself, pruning ".git" and ".thumbnails" so find
# never descends into them (neither their contents nor any README.md inside
# is ever visited).
#
# NOTE: this deliberately does NOT use "-mindepth 2" to exclude the root
# README. GNU find's -mindepth/-maxdepth are global depth filters that
# suppress evaluation of *all* tests -- including -prune -- for anything
# shallower than the threshold. Combined with -prune that means directories
# like "$root/.git" (depth 1) would never actually get pruned, and find would
# happily recurse into them anyway. Instead, -prune is left unconstrained by
# depth, and the root's own README.md is excluded explicitly by path.
find_readmes() {
    local root="$1"
    local root_readme="${root%/}/README.md"
    find "$root" \
        \( -type d \( -name '.git' -o -name "$THUMBNAIL_DIR_NAME" \) -prune \) \
        -o -type f -name 'README.md' -not -path "$root_readme" -print0
}

# Print, NUL-delimited and alphabetically sorted, every image file that lives
# directly inside $1 (no recursion), matching the configured extensions,
# skipping hidden files. ".thumbnails" is a directory, so "-type f" already
# excludes it here; there is nothing further to prune at this level.
find_images() {
    local dir="$1"
    local -a ext_array
    IFS=',' read -r -a ext_array <<< "$EXTENSIONS"

    local -a find_expr=()
    local ext
    for ext in "${ext_array[@]}"; do
        # Trim any accidental whitespace around an extension, e.g. "jpg, png"
        ext="${ext// /}"
        [[ -z "$ext" ]] && continue
        if (( ${#find_expr[@]} > 0 )); then
            find_expr+=( -o )
        fi
        find_expr+=( -iname "*.${ext}" )
    done

    (( ${#find_expr[@]} > 0 )) || return 0

    find "$dir" -mindepth 1 -maxdepth 1 -type f ! -name '.*' \( "${find_expr[@]}" \) -print0 \
        | LC_ALL=C sort -z
}

# -----------------------------------------------------------------------------
# Gallery generation
# -----------------------------------------------------------------------------

# Build a single gallery cell for one image: a link to the full-size original
# that displays the matching thumbnail when one exists, falling back to the
# original image itself when it doesn't. This function only ever reads the
# filesystem (a single -f test) — it never creates, deletes, or modifies
# anything under .thumbnails.
# Args: dir image_basename width
build_image_cell() {
    local dir="$1"
    local image="$2"
    local width="$3"

    local base_no_ext="${image%.*}"
    local thumb_rel="${THUMBNAIL_DIR_NAME}/${base_no_ext}.${THUMBNAIL_EXT}"
    local src="./${image}"

    if [[ -f "${dir}/${thumb_rel}" ]]; then
        src="./${thumb_rel}"
    else
        debug "Missing thumbnail for ${dir}/${image} (expected ${thumb_rel}); falling back to original."
    fi

    printf '<a href="./%s"><img src="%s" width="%s" alt="%s"></a>' \
        "$image" "$src" "$width" "$base_no_ext"
}

# Build the Markdown table for a list of image basenames.
# Args: dir columns width image_basename...
generate_table() {
    local dir="$1"
    local columns="$2"
    local width="$3"
    shift 3
    local -a images=("$@")
    local total=${#images[@]}

    if (( total == 0 )); then
        printf '_No images found in this directory._'
        return 0
    fi

    local header="|" sep="|"
    local i
    for (( i = 0; i < columns; i++ )); do
        header+=" |"
        sep+="---|"
    done

    local -a out_lines=()
    out_lines+=("$header")
    out_lines+=("$sep")

    local row="" idx=0 img cell
    for img in "${images[@]}"; do
        cell="$(build_image_cell "$dir" "$img" "$width")"
        row+="| ${cell} "
        (( ++idx ))
        if (( idx % columns == 0 )); then
            row+="|"
            out_lines+=("$row")
            row=""
        fi
    done

    # Pad an incomplete last row with empty cells.
    if (( idx % columns != 0 )); then
        local remaining=$(( columns - (idx % columns) ))
        for (( i = 0; i < remaining; i++ )); do
            row+="| "
        done
        row+="|"
        out_lines+=("$row")
    fi

    printf '%s\n' "${out_lines[@]}"
}

# -----------------------------------------------------------------------------
# README update
# -----------------------------------------------------------------------------

# Replace the content between PREVIEW markers in $1 with $2 (a possibly
# multi-line string). Creates the markers (with confirmation, unless --force
# or --dry-run) if they don't already exist. Writes atomically.
update_readme() {
    local readme="$1"
    local table="$2"
    local dir
    dir="$(dirname -- "$readme")"

    if [[ ! -r "$readme" ]]; then
        log "Skipping unreadable file: ${readme}"
        return 0
    fi

    local -a lines=()
    mapfile -t lines < "$readme"

    local start_idx=-1 end_idx=-1 i
    for i in "${!lines[@]}"; do
        if [[ "${lines[$i]}" == "$MARKER_START" ]]; then
            start_idx=$i
        elif [[ "${lines[$i]}" == "$MARKER_END" && $start_idx -ge 0 ]]; then
            end_idx=$i
            break
        fi
    done

    local -a new_lines=()

    if (( start_idx == -1 || end_idx == -1 )); then
        debug "No preview markers found in ${readme}"

        if (( FORCE == 0 )); then
            if [[ -t 0 ]]; then
                local reply
                read -r -p "No preview markers found in '${readme}'. Create them? [y/N] " reply
                if [[ ! "$reply" =~ ^[Yy]$ ]]; then
                    log "Skipped (markers not created): ${readme}"
                    return 0
                fi
            else
                log "Skipping ${readme}: markers missing and not running interactively (use --force to auto-create)."
                return 0
            fi
        fi

        new_lines=(
            "${lines[@]}"
            ""
            "## Preview"
            ""
            "$MARKER_START"
            ""
            "$table"
            ""
            "$MARKER_END"
        )
    else
        local -a before=("${lines[@]:0:start_idx+1}")
        local -a after=("${lines[@]:end_idx}")
        new_lines=(
            "${before[@]}"
            ""
            "$table"
            ""
            "${after[@]}"
        )
    fi

    if (( DRY_RUN )); then
        log "[dry-run] Would update: ${readme}"
        debug "Replacement status: dry-run, no file written"
        return 0
    fi

    if [[ ! -w "$dir" ]]; then
        log "Skipping ${readme}: directory not writable (${dir})"
        return 0
    fi
    if [[ ! -w "$readme" ]]; then
        log "Skipping ${readme}: file not writable"
        return 0
    fi

    local tmpfile
    if ! tmpfile="$(mktemp "${dir}/.README.md.XXXXXX" 2>/dev/null)"; then
        log "Skipping ${readme}: unable to create temp file in ${dir} (permission error?)"
        return 0
    fi
    TMP_FILES+=("$tmpfile")

    # Preserve the original file's permission bits on the replacement file.
    local orig_perms
    orig_perms="$(stat -c '%a' "$readme" 2>/dev/null || echo '644')"
    chmod "$orig_perms" "$tmpfile" 2>/dev/null || true

    printf '%s\n' "${new_lines[@]}" > "$tmpfile"
    mv -f -- "$tmpfile" "$readme"

    log "Updated: ${readme}"
    debug "Replacement status: success"
}

# -----------------------------------------------------------------------------
# Per-README processing
# -----------------------------------------------------------------------------
process_readme() {
    local readme="$1"
    local dir
    dir="$(dirname -- "$readme")"

    vlog "Processing directory: ${dir}"
    debug "README path: ${readme}"

    local -a raw_images=()
    mapfile -d '' -t raw_images < <(find_images "$dir")

    local -a basenames=()
    local img
    for img in "${raw_images[@]}"; do
        basenames+=("$(basename -- "$img")")
    done

    debug "Number of images found: ${#basenames[@]}"
    if (( DEBUG )) && (( ${#basenames[@]} > 0 )); then
        debug "Image list:"
        for img in "${basenames[@]}"; do
            printf '  - %s\n' "$img" >&2
        done
    fi

    local table
    table="$(generate_table "$dir" "$COLUMNS" "$WIDTH" "${basenames[@]}")"
    debug "Generated table:"
    (( DEBUG )) && printf '%s\n' "$table" >&2

    update_readme "$readme" "$table"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    validate_args

    local start_time end_time
    start_time="$(date +%s)"

    local processed=0

    while IFS= read -r -d '' readme; do
        process_readme "$readme"
        (( ++processed ))
    done < <(find_readmes "$ROOT_DIR")

    end_time="$(date +%s)"
    debug "Skipped directories: see per-file 'Skipping' messages above (if any)"
    debug "Execution time: $(( end_time - start_time ))s"

    if (( processed == 0 )); then
        log "No README.md files found to process under: ${ROOT_DIR} (root README.md is always ignored)"
    else
        log "Done. Processed ${processed} README.md file(s)."
    fi
}

main "$@"
