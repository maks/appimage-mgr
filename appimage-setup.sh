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
#   -i, --install-libfuse2      Install libfuse2 if it isn’t already.
#   -c, --create-desktop        Create/update .desktop files for the
#                               supplied AppImages (default if AppImages are given).
#   -l, --list                  List AppImages in ~/apps and show which have
#                               a .desktop file and which don’t.
#   -r, --remove-desktop FILE   Remove a specific .desktop entry (by name, not path).
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
    local basename_no_ext="${appimage_name%.*}"      # strip .AppImage
    local desktop_name="${PREFIX}-${basename_no_ext}.desktop"
    local desktop_path="${DESKTOPDIR}/${desktop_name}"

    # Optional: try to find an icon next to the AppImage (same basename, .png/.svg)
    local icon_path=""
    for ext in png svg jpg jpeg; do
        if [[ -f "${APPDIR}/${basename_no_ext}.${ext}" ]]; then
            icon_path="${APPDIR}/${basename_no_ext}.${ext}"
            break
        fi
    done

    # If we found an icon, copy it to the icon directory (so the launcher can find it)
    if [[ -n "$icon_path" ]]; then
        mkdir -p "${ICONDIR}"
        cp -f "$icon_path" "${ICONDIR}/${basename_no_ext}.${icon_path##*.}"
        icon_uri="Icon=${basename_no_ext}"
    else
        icon_uri="# Icon= (no icon found)"
    fi

    cat >"$desktop_path" <<EOF
[Desktop Entry]
Name=${basename_no_ext}
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

    # Build associative arrays for quick lookup
    declare -A has_desktop
    for d in "${desktop_files[@]}"; do
        # strip prefix and extension to get the corresponding AppImage base name
        base="${d#${PREFIX}-}"
        base="${base%.desktop}"
        has_desktop["$base"]=1
    done

    echo "=== AppImages with a matching .desktop entry ==="
    for a in "${appimages[@]}"; do
        name="${a%.*}"
        if [[ ${has_desktop[$name]+_} ]]; then
            echo "  ✔ $a"
        fi
    done

    echo
    echo "=== AppImages missing a .desktop entry ==="
    for a in "${appimages[@]}"; do
        name="${a%.*}"
        if [[ ! ${has_desktop[$name]+_} ]]; then
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

# ---------------------------------------------------------------

# Parse args
if [[ $# -eq 0 ]]; then
    usage
fi

CREATE_DESKTOP=false
INSTALL_LIBFUSE2=false
LIST_ONLY=false
REMOVE_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--install-libfuse2) INSTALL_LIBFUSE2=true; shift ;;
        -c|--create-desktop)   CREATE_DESKTOP=true; shift ;;
        -l|--list)              LIST_ONLY=true; shift ;;
        -r|--remove-desktop)    REMOVE_NAME="$2"; shift 2 ;;
        -h|--help)              usage ;;
        --) shift; break ;;
        *)                      APPARGS+=("$1"); shift ;;
    esac
done

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
if [[ ${#APPARGS[@]:-0} -eq 0 ]]; then
    # No explicit arguments – act on every *.AppImage in $APPDIR
    mapfile -t targets < <(find "$APPDIR" -maxdepth 1 -type f -iname "*.AppImage")
else
    # Expand possible globs (e.g. ~/apps/*.AppImage)
    mapfile -t targets < <(printf "%s\n" "${APPARGS[@]}")
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
