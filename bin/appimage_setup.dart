import 'dart:io';

/// Configuration constants
final String home = Platform.environment['HOME'] ?? '';
final String appDir = '$home/apps';
final String desktopDir = '$home/.local/share/applications';
final String iconDirScalable = '$home/.local/share/icons/hicolor/scalable/apps';
final String iconDirBitmap = '$home/.local/share/icons/hicolor/256x256/apps';
const String prefix = 'appimage';

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    printUsage();
    return;
  }

  bool createDesktop = false;
  bool forceDesktop = false;
  bool listOnly = false;
  String? showName;
  String? removeName;
  List<String> appArgs = [];

  // Manual argument parsing
  for (int i = 0; i < arguments.length; i++) {
    final arg = arguments[i];
    switch (arg) {
      case '-c':
      case '--create-desktop':
        createDesktop = true;
        break;
      case '-f':
      case '--force':
        forceDesktop = true;
        break;
      case '-l':
      case '--list':
        listOnly = true;
        break;
      case '-r':
      case '--remove':
        if (i + 1 < arguments.length) {
          removeName = arguments[++i];
        } else {
          print('✘ Error: --remove requires a name.');
          exit(1);
        }
        break;
      case '-s':
      case '--show-desktop':
        if (i + 1 < arguments.length) {
          showName = arguments[++i];
        } else {
          print('✘ Error: --show-desktop requires a name.');
          exit(1);
        }
        break;
      case '-h':
      case '--help':
        printUsage();
        exit(0);
      default:
        if (arg.startsWith('-')) {
          print('⚠ Unknown option: $arg');
          printUsage();
          exit(1);
        }
        appArgs.add(arg);
        break;
    }
  }

  checkLibfuse();

  if (showName != null) {
    showDesktopEntry(showName);
    exit(0);
  }

  if (removeName != null) {
    removeDesktopEntry(removeName);
    exit(0);
  }

  if (listOnly) {
    listStatus();
    exit(0);
  }

  // If AppImages provided but -c not specified, default to true (matches bash script)
  if (appArgs.isNotEmpty && !createDesktop) {
    createDesktop = true;
  }

  ensureDirectories();

  List<String> targets = [];
  if (appArgs.isEmpty) {
    // Act on every *.AppImage in appDir
    final dir = Directory(appDir);
    if (dir.existsSync()) {
      targets = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((path) => path.toLowerCase().endsWith('.appimage'))
          .toList();
    }
  } else {
    for (final arg in appArgs) {
      if (arg.contains('/') || arg.toLowerCase().endsWith('.appimage')) {
        final file = File(arg);
        if (file.existsSync()) {
          targets.add(file.absolute.path);
        } else {
          print('⚠ File not found: $arg');
        }
      } else {
        // Treat as basename
        final dir = Directory(appDir);
        if (dir.existsSync()) {
          final matches = dir
              .listSync()
              .whereType<File>()
              .map((f) => f.path)
              .where((path) {
                final name = getBasename(path);
                return name.toLowerCase().startsWith(arg.toLowerCase()) &&
                    path.toLowerCase().endsWith('.appimage');
              })
              .toList();
          if (matches.isNotEmpty) {
            targets.addAll(matches);
          } else {
            print('⚠ No AppImage found for basename \'$arg\' in $appDir');
          }
        }
      }
    }
  }

  if (targets.isEmpty) {
    print('⚠ No AppImage files found.');
    exit(1);
  }

  for (final appPath in targets) {
    final file = File(appPath);
    if (!file.existsSync()) {
      print('⚠ Skipping non‑existent file: $appPath');
      continue;
    }

    makeExecutable(appPath);

    if (createDesktop) {
      createDesktopEntry(appPath, forceDesktop);
    }
  }

  if (createDesktop) {
    updateDesktopDatabase();
  }
}

void printUsage() {
  print('''
appimage-setup.dart [options] [AppImage …]

Options:
  -s, --show-desktop NAME   Show the .desktop file for the given short name
  -r, --remove NAME         Remove the .desktop file for the given short name
  -c, --create-desktop        Create/update .desktop files for the
                              supplied AppImages (default if AppImages are given).
  -f, --force                 Overwrite existing .desktop files.
  -l, --list                  List AppImages in ~/apps and show which have
                              a .desktop file and which don’t.
  -h, --help                  Show this help message and exit.

Example:
  dart bin/appimage_setup.dart -c ~/apps/*.AppImage
  dart bin/appimage_setup.dart -r fquickshare
  dart bin/appimage_setup.dart -l
''');
}

void checkLibfuse() {
  if (File('/etc/fedora-release').existsSync()) {
    final result = Process.runSync('rpm', ['-q', 'fuse-libs']);
    if (result.exitCode == 0) {
      print('fuse-libs installed.');
    } else {
      print('✘ Error: fuse-libs (libfuse2) is not installed.');
      print('   Please install it manually: sudo dnf install fuse-libs');
      exit(1);
    }
  } else if (File('/etc/debian_version').existsSync()) {
    final result = Process.runSync('dpkg', ['-s', 'libfuse2']);
    if (result.exitCode == 0) {
      print('libfuse2 installed.');
    } else {
      print('✘ Error: libfuse2 is not installed.');
      print('   Please install it manually: sudo apt-get install libfuse2');
      exit(1);
    }
  } else {
    print('⚠ Unsupported distribution.');
  }
}

void makeExecutable(String path) {
  final result = Process.runSync('chmod', ['+x', path]);
  if (result.exitCode == 0) {
    print('✔ Made $path executable');
  } else {
    print('✘ Error making $path executable');
  }
}

void ensureDirectories() {
  Directory(appDir).createSync(recursive: true);
  Directory(desktopDir).createSync(recursive: true);
  Directory(iconDirScalable).createSync(recursive: true);
  Directory(iconDirBitmap).createSync(recursive: true);
}

String? extractIconFromAppimage(String appPath) {
  final fileName = getBasename(appPath);
  final fullBase = fileName.contains('.') 
      ? fileName.substring(0, fileName.lastIndexOf('.')) 
      : fileName;
  
  final tempDir = Directory.systemTemp.createTempSync('appimage-setup-');
  
  // Run extraction in the temporary directory
  final result = Process.runSync(
    appPath, 
    ['--appimage-extract'], 
    workingDirectory: tempDir.path
  );

  if (result.exitCode != 0) {
    tempDir.deleteSync(recursive: true);
    return null;
  }

  String? foundIcon;
  final searchRoots = [
    '${tempDir.path}/squashfs-root/usr/share/icons',
    '${tempDir.path}/squashfs-root/usr/share/pixmaps',
    '${tempDir.path}/squashfs-root',
  ];

  for (final root in searchRoots) {
    final rootDir = Directory(root);
    if (rootDir.existsSync()) {
      try {
        final files = rootDir.listSync(recursive: true, followLinks: false);
        for (final entity in files) {
          if (entity is File) {
            final name = getBasename(entity.path).toLowerCase();
            if ((name.endsWith('.png') || name.endsWith('.svg')) &&
                !name.contains('.symbolic.')) {
              foundIcon = entity.path;
              break;
            }
          }
        }
      } catch (_) {}
    }
    if (foundIcon != null) break;
  }

  if (foundIcon != null) {
    final ext = getExtension(foundIcon).toLowerCase();
    final targetDir = ext == '.svg' ? iconDirScalable : iconDirBitmap;
    Directory(targetDir).createSync(recursive: true);
    final dest = '$targetDir/$fullBase$ext';
    File(foundIcon).copySync(dest);
    tempDir.deleteSync(recursive: true);
    return dest;
  }

  tempDir.deleteSync(recursive: true);
  return null;
}

void createDesktopEntry(String appPath, bool force) {
  final fileName = getBasename(appPath);
  final fullBase = fileName.contains('.') 
      ? fileName.substring(0, fileName.lastIndexOf('.')) 
      : fileName;
  
  // short base: part before first - or _
  final shortBase = fullBase.split(RegExp(r'[-_]')).first;
  final desktopPath = '$desktopDir/$prefix-$shortBase.desktop';

  if (File(desktopPath).existsSync() && !force) {
    print('⚠ Desktop entry already exists: $desktopPath (use -f to overwrite)');
    return;
  }

  final wasExisting = File(desktopPath).existsSync();

  // Try to find icon next to AppImage
  String? iconPath;
  for (final ext in ['.png', '.svg', '.jpg', '.jpeg']) {
    final candidate = '$appDir/$fullBase$ext';
    if (File(candidate).existsSync()) {
      iconPath = candidate;
      break;
    }
  }

  String iconLine;
  if (iconPath != null) {
    final ext = getExtension(iconPath).toLowerCase();
    final targetDir = ext == '.svg' ? iconDirScalable : iconDirBitmap;
    Directory(targetDir).createSync(recursive: true);
    final dest = '$targetDir/$fullBase$ext';
    File(iconPath).copySync(dest);
    iconLine = 'Icon=$dest';
  } else {
    final extractedPath = extractIconFromAppimage(appPath);
    if (extractedPath != null) {
      iconLine = 'Icon=$extractedPath';
    } else {
      iconLine = '# Icon= (no icon found)';
    }
  }

  final content = '''[Desktop Entry]
Name=$shortBase
Exec="$appPath" %U
$iconLine
Terminal=false
Type=Application
Categories=Utility;
StartupNotify=true
''';

  File(desktopPath).writeAsStringSync(content);
  Process.runSync('chmod', ['+x', desktopPath]);

  if (wasExisting) {
    print('✔ Updated desktop entry: $desktopPath');
  } else {
    print('✔ Created desktop entry: $desktopPath');
  }
}

void listStatus() {
  Directory(appDir).createSync(recursive: true);
  Directory(desktopDir).createSync(recursive: true);

  print('Scanning $appDir for *.AppImage …');
  final appImages = Directory(appDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.appimage'))
      .map((f) => getBasename(f.path))
      .toList()..sort();

  print('Scanning $desktopDir for $prefix-*.desktop …');
  final desktopFiles = Directory(desktopDir)
      .listSync()
      .whereType<File>()
      .where((f) => getBasename(f.path).startsWith('$prefix-') && 
                    f.path.endsWith('.desktop'))
      .map((f) => getBasename(f.path))
      .toList()..sort();

  final hasDesktop = <String>{};
  for (final d in desktopFiles) {
    // strip prefix- and .desktop
    var base = d.substring(prefix.length + 1);
    if (base.endsWith('.desktop')) {
      base = base.substring(0, base.length - 8);
    }
    hasDesktop.add(base);
  }

  print('=== AppImages with a matching .desktop entry ===');
  for (final a in appImages) {
    final fullBase = a.contains('.') ? a.substring(0, a.lastIndexOf('.')) : a;
    final shortBase = fullBase.split(RegExp(r'[-_]')).first;
    if (hasDesktop.contains(shortBase)) {
      print('  ✔ $a');
    }
  }

  print('\n=== AppImages missing a .desktop entry ===');
  for (final a in appImages) {
    final fullBase = a.contains('.') ? a.substring(0, a.lastIndexOf('.')) : a;
    final shortBase = fullBase.split(RegExp(r'[-_]')).first;
    if (!hasDesktop.contains(shortBase)) {
      print('  ✘ $a');
    }
  }
}

void showDesktopEntry(String name) {
  final dir = Directory(desktopDir);
  if (!dir.existsSync()) {
    print('⚠ No desktop files found.');
    return;
  }

  final matches = dir.listSync()
      .whereType<File>()
      .where((f) => getBasename(f.path).startsWith('$prefix-$name') && 
                    f.path.endsWith('.desktop'))
      .toList();

  if (matches.isNotEmpty) {
    print(matches.first.readAsStringSync());
  } else {
    print('⚠ No desktop file found for name \'$name\'');
    exit(1);
  }
}

void removeDesktopEntry(String name) {
  final desktopPath = '$desktopDir/$prefix-$name.desktop';
  final file = File(desktopPath);
  if (file.existsSync()) {
    file.deleteSync();
    print('✔ Removed $desktopPath');
    updateDesktopDatabase();
  } else {
    print('⚠ No desktop file found at $desktopPath');
  }
}

void updateDesktopDatabase() {
  print('Updating desktop database...');
  final result = Process.runSync('update-desktop-database', [desktopDir]);
  if (result.exitCode == 0) {
    print('✅ Done.');
  } else {
    print('⚠ Note: update-desktop-database failed (is it installed?)');
  }
}

// Utility functions to replace package:path
String getBasename(String path) {
  final index = path.lastIndexOf(Platform.pathSeparator);
  return index == -1 ? path : path.substring(index + 1);
}

String getExtension(String path) {
  final fileName = getBasename(path);
  final index = fileName.lastIndexOf('.');
  return index == -1 ? '' : fileName.substring(index);
}
