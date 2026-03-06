package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const (
	prefix          = "appimage"
	appDir          = "$HOME/apps"
	desktopDir      = "$HOME/.local/share/applications"
	iconDirScalable = "$HOME/.local/share/icons/hicolor/scalable/apps"
	iconDirBitmap   = "$HOME/.local/share/icons/hicolor/256x256/apps"
)

type config struct {
	createDesktop bool
	force         bool
	listOnly      bool
	showName      string
	showDesktop   bool
	appArgs       []string
}

func main() {
	cfg, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	if cfg.showDesktop {
		showDesktopEntry(cfg.showName)
		return
	}

	if cfg.listOnly {
		listStatus()
		return
	}

	// Expand home dir
	appDirExpanded := expandHome(appDir)
	desktopDirExpanded := expandHome(desktopDir)
	iconDirBitmapExpanded := expandHome(iconDirBitmap)
	iconDirScalableExpanded := expandHome(iconDirScalable)

	if err := checkLibfuse(); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}

	var targets []string
	if len(cfg.appArgs) == 0 {
		targets, _ = findAppImages(appDirExpanded)
	} else {
		targets, _ = resolveArgs(cfg.appArgs, appDirExpanded)
	}

	if len(targets) == 0 {
		if len(cfg.appArgs) > 0 {
			fmt.Fprintf(os.Stderr, "⚠ No AppImage files found for the given arguments.\n")
		} else {
			fmt.Fprintf(os.Stderr, "⚠ No AppImage files found in %s.\n", appDirExpanded)
		}
		os.Exit(1)
	}

	if len(cfg.appArgs) > 0 && !cfg.createDesktop {
		cfg.createDesktop = true
	}

	os.MkdirAll(appDirExpanded, 0755)
	os.MkdirAll(desktopDirExpanded, 0755)
	os.MkdirAll(iconDirBitmapExpanded, 0755)
	os.MkdirAll(iconDirScalableExpanded, 0755)

	for _, app := range targets {
		appAbs, _ := filepath.Abs(app)
		if _, err := os.Stat(appAbs); os.IsNotExist(err) {
			fmt.Printf("⚠ Skipping non-existent file: %s\n", appAbs)
			continue
		}

		makeExecutable(appAbs)

		if cfg.createDesktop {
			createDesktopEntry(appAbs, cfg.force, desktopDirExpanded, iconDirBitmapExpanded, iconDirScalableExpanded)
		}
	}

	if cfg.createDesktop {
		fmt.Println("Updating desktop database...")
		updateDesktopDatabase(desktopDirExpanded)
		fmt.Println("✅ Done.")
	}
}

func parseArgs(args []string) (*config, error) {
	if len(args) == 0 {
		usage()
		os.Exit(0)
	}

	cfg := &config{}

	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-c", "--create-desktop":
			cfg.createDesktop = true
		case "-f", "--force":
			cfg.force = true
		case "-l", "--list":
			cfg.listOnly = true
		case "-s", "--show-desktop":
			cfg.showDesktop = true
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--show-desktop requires an argument")
			}
			cfg.showName = args[i+1]
			i++
		case "-h", "--help":
			usage()
			os.Exit(0)
		case "--":
			for j := i + 1; j < len(args); j++ {
				if !strings.HasPrefix(args[j], "-") {
					cfg.appArgs = append(cfg.appArgs, args[j])
				}
			}
		default:
			if !strings.HasPrefix(args[i], "-") {
				cfg.appArgs = append(cfg.appArgs, args[i])
			}
		}
	}

	return cfg, nil
}

func usage() {
	lines := []string{
		"# appimage-setup.sh",
		"",
		"# Automates the installation of libfuse2, makes AppImages executable,",
		"# creates consistent .desktop files and can report which AppImages already",
		"# have a desktop entry and which are missing one.",
		"",
		"# Requirements:",
		"#   • Ubuntu 24.04 (or any Debian-based distro)",
		"#   • libfuse2 must be installed manually before using this script",
		"",
		"# Usage:",
		"#   ./appimage-setup.sh [options] [AppImage …]",
		"",
		"# Options:",
		"#   -s, --show-desktop NAME   Show the .desktop file for the given short name",
		"#   -c, --create-desktop        Create/update .desktop files for the",
		"#                               supplied AppImages (default if AppImages are given).",
		"#   -f, --force                 Overwrite existing .desktop files.",
		"#   -l, --list                  List AppImages in ~/apps and show which have",
		"#                               a .desktop file and which don't.",
		"#   -h, --help                  Show this help message and exit.",
		"",
		"# Example:",
		"#   ./appimage-setup.sh -i -c ~/apps/*.AppImage",
		"#   ./appimage-setup.sh -l",
	}
	fmt.Println(strings.Join(lines, "\n"))
}

func checkLibfuse() error {
	distro := detectDistro()
	if distro == "" {
		return fmt.Errorf("⚠ Unsupported distribution.")
	}

	if distro == "fedora" {
		cmd := exec.Command("rpm", "-q", "fuse-libs")
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("✘ Error: fuse-libs (libfuse2) is not installed.\n   Please install it manually: sudo dnf install fuse-libs")
		}
		fmt.Println("fuse-libs installed.")
	} else {
		cmd := exec.Command("dpkg", "-s", "libfuse2")
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("✘ Error: libfuse2 is not installed.\n   Please install it manually: sudo apt-get install libfuse2")
		}
		fmt.Println("libfuse2 installed.")
	}
	return nil
}

func detectDistro() string {
	if _, err := os.Stat("/etc/fedora-release"); err == nil {
		return "fedora"
	}
	if _, err := os.Stat("/etc/debian_version"); err == nil {
		return "debian"
	}
	return ""
}

func makeExecutable(file string) {
	info, err := os.Stat(file)
	if err != nil {
		return
	}
	if info.Mode()&0111 != 0 {
		fmt.Printf("✔ %s already executable\n", file)
		return
	}
	if err := os.Chmod(file, info.Mode()|0111); err != nil {
		fmt.Printf("⚠ Failed to make %s executable: %v\n", file, err)
		return
	}
	fmt.Printf("✔ Made %s executable\n", file)
}

func extractIconFromAppImage(appimagePath, appDir, iconDirBitmap, iconDirScalable string) (string, error) {
	appimageName := filepath.Base(appimagePath)
	fullBase := stripExtension(appimageName)

	extractDir := filepath.Join(appDir, ".extract-"+fullBase)
	os.MkdirAll(extractDir, 0755)

	cmd := exec.Command(appimagePath, "--appimage-extract")
	cmd.Dir = extractDir
	if err := cmd.Run(); err != nil {
		os.RemoveAll(extractDir)
		return "", err
	}

	var iconFile string
	searchPaths := []string{
		"squashfs-root/usr/share/icons",
		"squashfs-root/usr/share/pixmaps",
		"squashfs-root",
	}

	for _, searchPath := range searchPaths {
		fullSearchPath := filepath.Join(extractDir, searchPath)
		if !dirExists(fullSearchPath) {
			continue
		}
		if found := findIcon(fullSearchPath, 2); found != "" {
			iconFile = found
			break
		}
	}

	if iconFile == "" {
		os.RemoveAll(extractDir)
		return "", fmt.Errorf("no icon found")
	}

	iconExt := strings.ToLower(filepath.Ext(iconFile))
	var targetDir string
	if iconExt == ".svg" {
		targetDir = iconDirScalable
	} else {
		targetDir = iconDirBitmap
	}
	dst := filepath.Join(targetDir, fullBase+iconExt)
	if err := copyFile(iconFile, dst); err != nil {
		os.RemoveAll(extractDir)
		return "", err
	}

	os.RemoveAll(extractDir)
	return dst, nil
}

func findIcon(dir string, maxDepth int) string {
	var result string
	filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil || result != "" {
			return nil
		}
		rel, _ := filepath.Rel(dir, path)
		depth := strings.Count(rel, string(filepath.Separator))
		if depth > maxDepth {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		name := strings.ToLower(d.Name())
		if strings.HasSuffix(name, ".png") || strings.HasSuffix(name, ".svg") {
			if strings.HasSuffix(name, ".symbolic.png") || strings.HasSuffix(name, ".symbolic.svg") {
				return nil
			}
			result = path
		}
		return nil
	})
	return result
}

func createDesktopEntry(appimagePath string, force bool, desktopDir, iconDirBitmap, iconDirScalable string) {
	appimageName := filepath.Base(appimagePath)
	fullBase := stripExtension(appimageName)
	shortBase := getShortBase(fullBase)

	desktopName := prefix + "-" + shortBase + ".desktop"
	desktopPath := filepath.Join(desktopDir, desktopName)

	if !force {
		if _, err := os.Stat(desktopPath); err == nil {
			fmt.Printf("⚠ Desktop entry already exists: %s (use -f to overwrite)\n", desktopPath)
			return
		}
	}

	wasExisting := false
	if _, err := os.Stat(desktopPath); err == nil {
		wasExisting = true
	}

	appDir := filepath.Dir(appimagePath)
	iconPath := findIconNextToAppImage(appimageName, fullBase, appDir)

	var iconURI string
	var iconDest string
	var iconExt string
	if iconPath != "" {
		iconExt = strings.ToLower(filepath.Ext(iconPath))
		var targetDir string
		if iconExt == ".svg" {
			targetDir = iconDirScalable
		} else {
			targetDir = iconDirBitmap
		}
		iconDest = filepath.Join(targetDir, fullBase+iconExt)
		if err := copyFile(iconPath, iconDest); err == nil {
			iconURI = "Icon=" + iconDest
		} else {
			iconURI = "# Icon= (failed to copy icon)"
		}
	} else {
		extractedPath, err := extractIconFromAppImage(appimagePath, appDir, iconDirBitmap, iconDirScalable)
		if err != nil {
			iconURI = "# Icon= (no icon found)"
		} else {
			iconURI = "Icon=" + extractedPath
		}
	}

	content := fmt.Sprintf("[Desktop Entry]\nName=%s\nExec=\"%s\" %%U\n%s\nTerminal=false\nType=Application\nCategories=Utility;\nStartupNotify=true\n",
		shortBase, appimagePath, iconURI)

	if err := os.WriteFile(desktopPath, []byte(content), 0755); err != nil {
		fmt.Printf("⚠ Failed to create desktop entry: %v\n", err)
		return
	}

	if wasExisting {
		fmt.Printf("✔ Updated desktop entry: %s\n", desktopPath)
	} else {
		fmt.Printf("✔ Created desktop entry: %s\n", desktopPath)
	}
}

func findIconNextToAppImage(appimageName, fullBase, appDir string) string {
	extensions := []string{"png", "svg", "jpg", "jpeg"}
	for _, ext := range extensions {
		iconPath := filepath.Join(appDir, fullBase+"."+ext)
		if _, err := os.Stat(iconPath); err == nil {
			return iconPath
		}
	}
	return ""
}

func listStatus() {
	appDirExpanded := expandHome(appDir)
	desktopDirExpanded := expandHome(desktopDir)

	os.MkdirAll(appDirExpanded, 0755)
	os.MkdirAll(desktopDirExpanded, 0755)

	fmt.Printf("Scanning %s for *.AppImage …\n", appDirExpanded)
	appimages, _ := findAppImages(appDirExpanded)

	fmt.Printf("Scanning %s for %s-*.desktop …\n", desktopDirExpanded, prefix)
	desktopFiles, _ := findDesktopFiles(desktopDirExpanded, prefix)

	hasDesktop := make(map[string]bool)
	for _, d := range desktopFiles {
		base := strings.TrimPrefix(d, prefix+"-")
		base = strings.TrimSuffix(base, ".desktop")
		hasDesktop[base] = true
	}

	fmt.Println("=== AppImages with a matching .desktop entry ===")
	for _, a := range appimages {
		fullBase := stripExtension(a)
		shortBase := getShortBase(fullBase)
		if hasDesktop[shortBase] {
			fmt.Printf("  ✔ %s\n", a)
		}
	}

	fmt.Println()
	fmt.Println("=== AppImages missing a .desktop entry ===")
	for _, a := range appimages {
		fullBase := stripExtension(a)
		shortBase := getShortBase(fullBase)
		if !hasDesktop[shortBase] {
			fmt.Printf("  ✘ %s\n", a)
		}
	}
}

func showDesktopEntry(name string) {
	desktopDirExpanded := expandHome(desktopDir)
	pattern := filepath.Join(desktopDirExpanded, prefix+"-"+name+"*.desktop")

	matches, err := filepath.Glob(pattern)
	if err != nil || len(matches) == 0 {
		fmt.Printf("⚠ No desktop file found for name '%s'\n", name)
		os.Exit(1)
	}

	file, err := os.Open(matches[0])
	if err != nil {
		fmt.Printf("⚠ Failed to open desktop file: %v\n", err)
		os.Exit(1)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fmt.Println(scanner.Text())
	}
}

func expandHome(path string) string {
	if strings.HasPrefix(path, "$HOME") {
		return strings.Replace(path, "$HOME", os.Getenv("HOME"), 1)
	}
	return path
}

func findAppImages(dir string) ([]string, error) {
	var files []string
	filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		name := strings.ToLower(d.Name())
		if strings.HasSuffix(name, ".appimage") {
			files = append(files, path)
		}
		return nil
	})
	sort.Strings(files)
	return files, nil
}

func findDesktopFiles(dir, prefix string) ([]string, error) {
	var files []string
	filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		if strings.HasPrefix(d.Name(), prefix) && strings.HasSuffix(d.Name(), ".desktop") {
			files = append(files, path)
		}
		return nil
	})
	sort.Strings(files)
	return files, nil
}

func resolveArgs(args []string, appDir string) ([]string, error) {
	appimages, _ := findAppImages(appDir)
	var targets []string
	foundAny := false

	for _, arg := range args {
		if strings.Contains(arg, "/") || strings.HasSuffix(arg, ".AppImage") {
			matches, _ := findAppImages(filepath.Dir(arg))
			for _, m := range matches {
				targets = append(targets, m)
			}
			if len(matches) == 0 {
				fmt.Printf("⚠ No AppImage found for '%s'\n", arg)
			}
			foundAny = true
		} else {
			argBase := strings.TrimSuffix(strings.ToLower(arg), ".appimage")
			for _, m := range appimages {
				name := filepath.Base(m)
				nameLower := strings.ToLower(name)
				fullBase := strings.TrimSuffix(nameLower, ".appimage")
				shortBase := getShortBase(fullBase)
				if strings.HasPrefix(shortBase, argBase) || strings.HasPrefix(fullBase, argBase) {
					targets = append(targets, m)
					foundAny = true
				}
			}
			if !foundAny {
				fmt.Printf("⚠ No AppImage found for basename '%s' in %s\n", arg, appDir)
			}
		}
	}

	if len(targets) == 0 && foundAny {
		fmt.Fprintf(os.Stderr, "⚠ No AppImage files found for the given arguments.\n")
		return nil, fmt.Errorf("no targets found")
	}

	return targets, nil
}

func updateDesktopDatabase(dir string) {
	cmd := exec.Command("update-desktop-database", dir)
	if err := cmd.Run(); err != nil {
		fmt.Printf("⚠ Failed to update desktop database: %v\n", err)
	}
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.IsDir()
}

func copyFile(src, dst string) error {
	source, err := os.Open(src)
	if err != nil {
		return err
	}
	defer source.Close()

	destination, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destination.Close()

	_, err = copy(source, destination)
	return err
}

func copy(dst *os.File, src *os.File) (int64, error) {
	return io.Copy(dst, src)
}

func stripExtension(name string) string {
	idx := strings.LastIndex(name, ".")
	if idx == -1 {
		return name
	}
	return name[:idx]
}

func getShortBase(fullBase string) string {
	idx := -1
	for i, ch := range fullBase {
		if ch == '-' || ch == '_' {
			idx = i
			break
		}
	}
	if idx == -1 {
		return fullBase
	}
	return fullBase[:idx]
}
