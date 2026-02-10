# AppImage Manager

A bash script to automate AppImage setup on Ubuntu/Debian-based systems.

## Features

- Install libfuse2 dependency (required for AppImage runtime)
- Make AppImages executable
- Create .desktop files for application integration
- List AppImages and show which have desktop entries
- Show desktop entry contents
- Copy icons from AppImage files to system icon directory

## Requirements

- Fedora 43 or Ubuntu 24.04
- sudo privileges for libfuse2 installation

## Installation

No installation required. Just download the script and make it executable:

```bash
chmod +x appimage-setup.sh
```

## Usage

```bash
./appimage-setup.sh [options] [AppImage ...]
```

### Options

| Option | Description |
|--------|-------------|
| `-s, --show-desktop NAME` | Show the .desktop file for the given short name |
| `-i, --install-libfuse2` | Install libfuse2 if it isn't already |
| `-c, --create-desktop` | Create/update .desktop files for the supplied AppImages (default if AppImages are given) |
| `-l, --list` | List AppImages in ~/apps and show which have a .desktop file and which don't |
| `-h, --help` | Show help message and exit |

### Examples

```bash
# Install libfuse2 and create desktop entries for all AppImages
./appimage-setup.sh -i -c ~/apps/*.AppImage

# List all AppImages and their desktop entry status
./appimage-setup.sh -l

# Show a desktop entry for an app named "vlc"
./appimage-setup.sh -s vlc
```

## Configuration

The following directories can be configured in the script (lines 36-39):

- APPDIR: Where your AppImages are stored (default: ~/apps)
- DESKTOPDIR: Where .desktop files are created (default: ~/.local/share/applications)
- ICONDIR: Where icons are copied (default: ~/.local/share/icons/hicolor/256x256/apps)
- PREFIX: Prefix for desktop filename (default: appimage)

Desktop entries are named like `appimage-{short-name}.desktop` where `{short-name}` is extracted from the AppImage filename.

