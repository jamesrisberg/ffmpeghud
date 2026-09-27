# Changelog

All notable changes to ffmpegHUD are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/); the current version is in [VERSION](VERSION).

## [Unreleased]

## [0.1.0] - 2026-09-27

### Added
- `ffmpegHUDKit` (no UI): preset catalog (Convert format, Compress, Resize, Trim, Make a GIF,
  Extract audio, Remove audio, Change speed, Thumbnail, Join clips, Rotate / flip, Crop to
  aspect, Web-ready MP4, Change container, Normalize loudness), argv builder (never a shell;
  ffmpeg runs with `-n`), never-overwrite output naming, ffprobe media info, progress parsing,
  runner and a job queue that runs `jobs.concurrent` jobs at once; Cancel and Quit stop ffmpeg
  and remove partial outputs.
- Hover panel `tools` on HUD glass (Control-Option-F, menu bar, MacHUD dock): drop zone with
  ffprobe details, preset list (recent first, search, video-only presets dimmed for audio),
  prefilled form that marks encoders this ffmpeg lacks, live command preview with copy, jobs
  with progress, Cancel, Reveal and errors; 44 pt compact drop tile with a running-jobs badge
  and progress ring; parked mode. Dismiss hides, never quits.
- MacHUD contract through HUDKit: manifest (`xyz.machud.ffmpeghud`, dock `order` 3,
  `acceptsFileDrop`), settings schema (`output.folder`, `output.customFolder`, `naming.suffix`,
  `keepOriginal`, `jobs.concurrent`), `action drop|run|jobs|cancel|presets|snapshot`; slides out
  of the dock edge and never takes key on hover. Drops accept `file://` segments and decode
  HUDKit's `HUDDrop` encoding.
- Menu bar consolidation: while MacHUD runs, the app's menu appears in MacHUD's status menu
  (`menu`, `menu-invoke`) and its own icon hides; `menuBar.consumed` (default `true`) is kept in
  `<home>/menubar.json`. `hello` reports `statusItem`.
- App icon and menu bar icon from the MacHUD family set (`AppIcon.icns`, `MenuBarIcon.png`/`@2x`),
  with the SF Symbol `film.stack` as the fallback.
- `ffmpeghud` CLI: `drop`, `run` (with `wait=1`), `jobs`, `cancel`, `presets`, `watch`, plus the
  HUDKit verbs.
- `--snapshot <png>` (with `--snapshot-mode`, `--snapshot-delay`, `--drop`, `--preset`, `--run`)
  and `FFMPEGHUD_HOME` / `_SOCKET` / `_NO_HOTKEYS` isolation for testing.
- Repo layout per HUDKit's docs/CONVENTIONS.md: targets `ffmpegHUDKit`, `ffmpegHUD`,
  `ffmpegHUDCLI`, `ffmpegHUDKitTests`, `ffmpegHUDTests`; `build.sh` / `install.sh` call HUDKit's
  shared scripts; CI runs `swift test` on macOS.
