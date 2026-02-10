#!/usr/bin/env bash
#
# appimage-setup.sh
#
# Automates the installation of libfuse2, makes AppImages executable,
# creates consistent .desktop files and can report which AppImages already
# have a desktop entry and which are missing one.
#
# Requirements:
#   • Ubuntu 24.04 (or any Debian-based distro)
#   • sudo privileges for the libfuse2 installation
#
# Usage:
#   ./appimage-setup.sh [options] [AppImage …]
#
# Options:
#   -s, --show-desktop NAME   Show the .desktop file for the given short name
#   -i, --install-libfuse2      Install libfuse2 if it isn’t already.
#   -c, --create-desktop        Create/update .desktop files for the
#                               supplied AppImages (default if AppImages are given).
#   -l, --list                  List AppImages in ~/apps and show which have
#                               a .desktop file and which don’t.
#           -s, --show-desktop NAME   Show the .desktop file for the given short name
#   -h, --help                  Show this help message and exit.
#
# Example:
#   ./appimage-setup.sh -i -c ~/apps/*.AppImage
#   ./appimage-setup.sh -l
#
# ---------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# ----- Configurable constants ------------------------------------
APPDIR="${HOME}/apps"
DESKTOPDIR="${HOME}/.local/share/applications"
PREFIX="appimage"               # prefix used for .desktop filenames
ICONDIR="${HOME}/.local/share/icons/hicolor/256x256/apps"

# ---------------------------------------------------------------

usage() {
    grep '^# ' "$0" | sed 's/^# //'
    exit 0
}

install_libfuse2() {
    if dpkg -s libfuse2 >/dev/null 2>&1; then
        echo "libfuse2 already installed."
    else
        echo "Installing libfuse2..."
        sudo apt-get update -qq
        sudo apt-get install -y libfuse2
        echo "libfuse2 installed."
    fi
}

make_executable() {
    local file=$1
    if [[ -x "$file" ]]; then
        echo "✔ $file already executable"
    else
        chmod +x "$file"
        echo "✔ Made $file executable"
    fi
}

create_desktop_entry() {
    local appimage_path=$1
    local appimage_name
    appimage_name=$(basename "$appimage_path")
    # Full base name without extension
    local full_base="${appimage_name%.*}"
    # Short base name (up to first dash) for desktop entry naming
-    local short_base="${full_base%%-*}"
+    # Short base name: part before first dash or underscore
+    local short_base="${full_base%%[-_]*}"

    local desktop_name="${PREFIX}-${short_base}.desktop"
    local desktop_path="${DESKTOPDIR}/${desktop_name}"

    # Optional: try to find an icon next to the AppImage (same full base name, .png/.svg)
    local icon_path=""
    for ext in png svg jpg jpeg; do
        if [[ -f "${APPDIR}/${full_base}.${ext}" ]]; then
            icon_path="${APPDIR}/${full_base}.${ext}"
            break
        fi
    done

    # If we found an icon, copy it to the icon directory (so the launcher can find it)
    if [[ -n "$icon_path" ]]; then
        mkdir -p "${ICONDIR}"
        cp -f "$icon_path" "${ICONDIR}/${full_base}.${icon_path##*.}"
        icon_uri="Icon=${full_base}"
    else
        icon_uri="# Icon= (no icon found)"
    fi

    cat >"$desktop_path" <<EOF
[Desktop Entry]
Name=${short_base}
Exec="${appimage_path}" %U
${icon_uri}
Terminal=false
Type=Application
Categories=Utility;
StartupNotify=true
EOF

    chmod +x "$desktop_path"
    echo "✔ Created desktop entry: $desktop_path"
}

list_status() {
    echo "Scanning ${APPDIR} for *.AppImage …"
    mapfile -t appimages < <(find "$APPDIR" -maxdepth 1 -type f -iname "*.AppImage" -printf "%f\n" | sort)

    echo "Scanning ${DESKTOPDIR} for ${PREFIX}-*.desktop …"
    mapfile -t desktop_files < <(find "$DESKTOPDIR" -maxdepth 1 -type f -name "${PREFIX}-*.desktop" -printf "%f\n" | sort)

    # Build associative arrays for quick lookup (short base names)
    declare -A has_desktop
    for d in "${desktop_files[@]}"; do
        # strip prefix and extension to get the short base name used for the desktop file
        base="${d#${PREFIX}-}"
        base="${base%.desktop}"
        has_desktop["$base"]=1
    done

    echo "=== AppImages with a matching .desktop entry ==="
    for a in "${appimages[@]}"; do
        full_base="${a%.*}"
        short_base="${full_base%%-*}"
        if [[ ${has_desktop[$short_base]+_} ]]; then
            echo "  ✔ $a"
        fi
    done

    echo
    echo "=== AppImages missing a .desktop entry ==="
    for a in "${appimages[@]}"; do
        full_base="${a%.*}"
        short_base="${full_base%%-*}"
        if [[ ! ${has_desktop[$short_base]+_} ]]; then
            echo "  ✘ $a"
        fi
    done
}

remove_desktop_entry() {
    local name=$1
    local target="${DESKTOPDIR}/${PREFIX}-${name}.desktop"
    if [[ -f "$target" ]]; then
        rm -f "$target"
        echo "Removed $target"
    else
        echo "No desktop file called $target"
    fi
}

show_desktop_entry() {
    local name=$1
    # Look for a desktop file starting with the given short name
    local pattern="${DESKTOPDIR}/${PREFIX}-${name}*.desktop"
    shopt -s nullglob
    local matches=( $pattern )
    shopt -u nullglob
    if (( ${#matches[@]} )); then
        cat "${matches[0]}"
    else
        echo "⚠ No desktop file found for name '$name'"
        return 1
    fi
}

# ---------------------------------------------------------------

# Parse args
if [[ $# -eq 0 ]]; then
    usage
fi

CREATE_DESKTOP=false
INSTALL_LIBFUSE2=false
LIST_ONLY=false
REMOVE_NAME=""
SHOW_NAME=""
SHOW_DESKTOP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--install-libfuse2) INSTALL_LIBFUSE2=true; shift ;;
        -c|--create-desktop)   CREATE_DESKTOP=true; shift ;;
        -l|--list)              LIST_ONLY=true; shift ;;
        -s|--show-desktop)    SHOW_DESKTOP=true; SHOW_NAME="$2"; shift 2 ;;
        -h|--help)              usage ;;
        --) shift; break ;;
        *)                      APPARGS+=("$1"); shift ;;
    esac
done

# 1. Show desktop entry if requested
if $SHOW_DESKTOP; then
    show_desktop_entry "$SHOW_NAME"
    exit 0
fi

# 1. Install libfuse2 if requested
if $INSTALL_LIBFUSE2; then
    install_libfuse2
fi

# 2. List mode (no other actions)
if $LIST_ONLY; then
    list_status
    exit 0
fi

# 3. Remove a desktop entry if asked
if [[ -n "$REMOVE_NAME" ]]; then
    remove_desktop_entry "$REMOVE_NAME"
    exit 0
fi

# 4. Process supplied AppImages (or all in $APPDIR if none given)
if [[ ${#APPARGS[@]} -eq 0 ]]; then
    # No explicit arguments – act on every *.AppImage in $APPDIR
    mapfile -t targets < <(find "$APPDIR" -maxdepth 1 -type f -iname "*.AppImage")
else
    # Resolve each argument: if it looks like a path or glob, keep it; otherwise treat as basename and find matching AppImage(s)
    resolved=()
    for arg in "${APPARGS[@]}"; do
        if [[ "$arg" == */* ]] || [[ "$arg" == *.AppImage ]]; then
            # Assume it's a path or glob; expand via printf (keeps as is)
            resolved+=("$arg")
        else
            # Treat as basename: find files starting with this name
            mapfile -t matches < <(find "$APPDIR" -maxdepth 1 -type f -iname "${arg}*AppImage")
            if [[ ${#matches[@]} -gt 0 ]]; then
                resolved+=("${matches[@]}")
            else
                echo "⚠ No AppImage found for basename '$arg'"
            fi
        fi
    done
    # Expand possible globs now (e.g. ~/apps/*.AppImage) and collect into targets
    mapfile -t targets < <(printf "%s\n" "${resolved[@]}")
fi

if [[ ${#targets[@]} -eq 0 ]]; then
    echo "⚠ No AppImage files found to process."
    exit 1
fi

# Ensure desktop directory exists
mkdir -p "$DESKTOPDIR"

# Main loop
for app in "${targets[@]}"; do
    # Resolve to absolute path (handles ~/)
    app=$(realpath -s "$app")
    # Sanity check
    if [[ ! -f "$app" ]]; then
        echo "⚠ Skipping non‑existent file: $app"
        continue
    fi

    make_executable "$app"

    if $CREATE_DESKTOP; then
        create_desktop_entry "$app"
    fi
done

# Update the desktop database once after all entries are written
if $CREATE_DESKTOP; then
    echo "Updating desktop database..."
    update-desktop-database "${DESKTOPDIR}"
    echo "✅ Done."
fi
