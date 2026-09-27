# ffmpegHUD

ffmpeg without the flags, for macOS. Drop a video or audio file on the panel, pick a preset
(Make a GIF, Compress, Trim, Extract audio...), adjust its prefilled fields, and Run. macOS 14+.

## What it is

ffmpegHUD is a menu bar app (no Dock icon) with one `hover` panel on HUD glass. The command it
will run is shown live under the form, jobs run in the background with progress bars, and the
result lands next to the original under a new name. Existing files are never overwritten. On
its own it shows the panel from the menu bar icon or Control-Option-F; inside MacHUD it is a
hover button in the tool dock whose panel slides out while the pointer is over it, and you can
drop files straight onto the button.

Needs ffmpeg and ffprobe (`brew install ffmpeg`); they are found on PATH and in the Homebrew
prefixes, since an app launched from Finder gets a bare PATH.

## Install

Check out HUDKit (the shared kit and build scripts) next to this repo, then install:

```sh
ls ~/dev            # hudkit  ffmpeghud
~/dev/ffmpeghud/install.sh
```

`install.sh` builds a release, quits a running copy, installs `/Applications/ffmpegHUD.app`,
links the `ffmpeghud` command onto your PATH and launches it.

## Use

| Key | Does |
|---|---|
| Control-Option-F | show or hide the panel (focused) |
| Cmd-Return | Run |
| Esc, Cmd-W | hide the panel |

The menu bar icon (`film.stack`) shows the panel and has Compact Tile, Choose Files...,
Reveal Output Folder, Cancel All Jobs and Quit. Drag and drop: video or audio files, from
Finder onto the panel or its compact tile, or onto ffmpegHUD's button in the MacHUD dock
(hover the button to drop the panel down and drop onto that).

- **Drop zone.** "Drop video or audio here" until you do; then the file's name and what
  ffprobe says about it: duration, resolution, codecs, size. Drop several files and Run makes
  one job per file (Join clips joins them, in the order they were dragged).
- **Presets.** Recently used first, then the rest; the search field filters by name. Presets
  that need a picture are dimmed for audio-only files.
- **Form.** The preset's fields, prefilled with sensible values. Choices that need an encoder
  your ffmpeg lacks are marked "(not in this ffmpeg)" and cannot be picked (Homebrew's ffmpeg,
  for instance, has no libx265 or libvpx, so H.265 and WebM are unavailable there).
- **Command preview.** The exact argv the job will run, shell-quoted for copying (the copy
  button), and the output path. ffmpegHUD never runs a shell; the argv goes straight to ffmpeg.
- **Run** (Cmd-Return). Jobs run two at a time by default, the rest wait.
- **Jobs.** Each with a progress bar (from ffmpeg's `time=` against the duration ffprobe
  reported, adjusted for trims and speed changes), Cancel (the partial output is removed),
  Reveal in Finder when done, and an errors disclosure with what ffmpeg said when it failed.
- **Compact tile.** A 44 pt tile with the ffmpeg glyph, a badge counting running jobs and a
  ring for their progress. Drop a file on it or click it to open the full panel.
- **Dismiss.** The close button, Esc or Cmd-W hide the panel; summoning it again (hotkey, menu
  bar, MacHUD) restores it as it was.

## Presets

| Preset | What it does |
|---|---|
| Convert format | MP4, WebM, MOV, MKV or AVI, re-encoded |
| Compress | H.264 or H.265 at a CRF (18/23/28/32) and an encoding speed |
| Resize | 4K, 1080p, 720p, 480p, half size or a custom `W:H` (keeps the aspect ratio) |
| Trim | start and duration; exact (re-encode) or fast (stream copy, cuts at keyframes) |
| Make a GIF | palette-optimised, 10/15/24 fps, 320-800 px wide, optional start and duration |
| Extract audio | MP3, AAC (.m4a), WAV, FLAC or Opus, with a bitrate |
| Remove audio | copies the picture, drops the sound |
| Change speed | 0.25x to 4x, picture and sound together |
| Thumbnail | one frame at a chosen time, as JPEG or PNG, at a chosen width |
| Join clips | concatenates the dropped files (fast copy or re-encode) |
| Rotate / flip | 90° either way, 180°, horizontal or vertical flip |
| Crop to aspect | centre crop to 1:1, 9:16, 16:9 or 4:3 |
| Web-ready MP4 | H.264, yuv420p, `+faststart`, AAC |
| Change container | rewrap without re-encoding |
| Normalize loudness | EBU R128 to -16, -14 or -23 LUFS |

## Output

Results are named `<original><suffix>.<ext>`, the suffix being the `naming.suffix` setting
(`_{preset}` by default, so `clip_gif.gif`, `clip_compressed.mp4`). If that name exists, or
another queued job has claimed it, `-2`, `-3`... is added. They go in the original's folder,
`~/Movies` or a folder you choose (`output.folder`). With `keepOriginal` off, the original is
moved to the Trash (never deleted) after a job succeeds.

## MacHUD contract

Panel `tools`, kind `hover`, capability `acceptsFileDrop`, dock `order` 3, socket `ffmpeghud`.
Verbs: the HUDKit set (`hello`, `state`, `subscribe`, `panel show|hide|toggle|frame|mode`,
`settings get|set|schema`, `action`, `quit`) plus `action drop|run|jobs|cancel|presets|snapshot`.
Full reference: [docs/CONTRACT.md](docs/CONTRACT.md).

`ffmpeghud` (in `ffmpegHUD.app/Contents/Helpers`, linked onto PATH by `install.sh`) drives the
running app:

```sh
ffmpeghud drop ~/Movies/clip.mov                  # as if dropped on the panel
ffmpeghud run gif ~/Movies/clip.mov fps=10 width=320 wait=1
ffmpeghud run trim clip.mov start=00:01:05 duration=30
ffmpeghud jobs
ffmpeghud cancel id=3
ffmpeghud presets                                 # ids and fields
```

## Settings

| Key | Type | Default | |
|---|---|---|---|
| `output.folder` | `same` / `movies` / `custom` | `same` | where results go: the original's folder, `~/Movies`, or `output.customFolder` |
| `output.customFolder` | path | `""` | required when `output.folder` is `custom` |
| `naming.suffix` | string | `_{preset}` | added to the original's name; no `/` or `:` |
| `keepOriginal` | bool | `true` | off: the original is moved to the Trash after its job succeeds |
| `jobs.concurrent` | int (1-8) | `2` | jobs run at once |

Set them in MacHUD's settings window or with `ffmpeghud settings set key=value`. Stored in
`~/Library/Application Support/ffmpegHUD/preferences.json`.

## Build from source

Needs Swift 5.9+ and HUDKit checked out next to this repo (`../hudkit`).

```sh
swift test          # ffmpegHUDKitTests (every preset's argv, naming, progress, probe; live runs on
                    # lavfi-generated clips when ffmpeg is installed) + ffmpegHUDTests (the socket
                    # host, the manifest, settings schema and Info.plist)
./build.sh          # build/ffmpegHUD.app, CLI at Contents/Helpers/ffmpeghud (./build.sh debug for debug)
./install.sh        # build, install to /Applications, link `ffmpeghud` onto PATH, launch
build/ffmpegHUD.app/Contents/MacOS/ffmpegHUD --snapshot /tmp/ffmpeghud.png [--snapshot-mode compact] \
    [--snapshot-delay 3] [--drop <file>] [--preset <id>] [--run]
```

`--snapshot` writes a PNG of the panel after launch (the glass is drawn as a dark stand-in),
for checking the UI without Screen Recording permission; `action snapshot path=` does the same
on a running instance.

`build.sh` and `install.sh` call HUDKit's shared `scripts/hud-build.sh` and
`scripts/hud-install.sh` (set `HUDKIT_DIR` if HUDKit lives elsewhere). The version comes from
[VERSION](VERSION); changes are in [CHANGELOG.md](CHANGELOG.md).

Layout: `Sources/ffmpegHUDKit` (presets, argv builder, naming, probe, progress, runner, jobs;
no UI), `Sources/ffmpegHUD` (the app; `Resources/` holds Info.plist, the manifest and the
settings schema), `Sources/ffmpegHUDCLI` (the `ffmpeghud` tool).

## Isolation env vars for testing

| Variable | Effect |
|---|---|
| `FFMPEGHUD_HOME` | base directory for everything ffmpegHUD writes (default `~/Library/Application Support/ffmpegHUD`); also keeps panel frames and recent presets apart |
| `FFMPEGHUD_SOCKET` | socket name (default `ffmpeghud`); the CLI honours it too |
| `FFMPEGHUD_NO_HOTKEYS` | set to skip registering the global hotkey |

```sh
FFMPEGHUD_HOME=$(mktemp -d) FFMPEGHUD_SOCKET=ffmpeghud-test FFMPEGHUD_NO_HOTKEYS=1 \
  build/ffmpegHUD.app/Contents/MacOS/ffmpegHUD &
FFMPEGHUD_SOCKET=ffmpeghud-test build/ffmpegHUD.app/Contents/Helpers/ffmpeghud hello
FFMPEGHUD_SOCKET=ffmpeghud-test build/ffmpegHUD.app/Contents/Helpers/ffmpeghud quit
```

## License

MIT, see [LICENSE](LICENSE).
