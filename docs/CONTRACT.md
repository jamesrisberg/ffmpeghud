# ffmpegHUD's MacHUD contract

ffmpegHUD implements the MacHUD contract through HUDKit; the canonical spec is HUDKit's
[docs/CONTRACT.md](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md). MacHUD
reads `ffmpegHUD.app/Contents/Resources/machud.json` without launching the app and talks to
the running app over a Unix socket.

The shared parts are specified there and not repeated here: [socket](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#socket) (location,
framing, replies), the [required verbs](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#verbs), [`subscribe`](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#subscribe-and-state-events),
the [settings schema](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#settings-schema) format, [hover and windowed behaviour](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#behaviour-hover-and-windowed),
[file drops](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#file-drops), the [launch announcement](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#launch-announcement) and [menu bar consolidation](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#menu-bar-consolidation).
This page lists what ffmpegHUD adds.

- Manifest: `Sources/ffmpegHUD/Resources/machud.json`: app `xyz.machud.ffmpeghud`, socket `ffmpeghud`, one panel
  `tools` (`kind: hover`, symbol `film.stack`, default 640x500, compact 44x44, capability
  `acceptsFileDrop`, settings schema `settings.json`, dock `order` 3: after Scratch and Stash).
- Hover: MacHUD shows the panel while the pointer is over its dock button and hides it on
  leave. `panel show`/`hide`/`toggle` fade in 0.22 s / out 0.18 s and keep the last frame and
  mode; a socket show never activates ffmpegHUD, and only `reason=click`/`summon` makes the
  panel key (a click on a field does too). Dock options: `from=<edge>` slides out of that edge
  to the `panel frame` MacHUD assigned (else next to `anchor=x,y,w,h`), in 0.08 s with
  `reason=hover`; `hide to=<edge>` slides back in 0.1 s. A show during a hide wins. The
  Control-Option-F hotkey and the menu bar item show it focused. Dismiss (the close button,
  Esc, Cmd-W) hides; it never quits.
- File drops on the dock button arrive as `action drop paths=`; see below.
- Socket: `~/Library/Application Support/MacHUD/sockets/ffmpeghud.sock` (0600), one JSON object
  per line: `{"command": "...", "args": {...}}` in, `{"ok": true, ...}` or
  `{"ok": false, "error": "..."}` out.
- CLI: `ffmpeghud <command> [key=value ...]` (in `ffmpegHUD.app/Contents/Helpers/ffmpeghud`).
  `drop`, `run`, `jobs`, `cancel` and `presets` are shorthands for `action name=<verb>`; `drop`
  and `run` take bare file arguments, resolve them against the current directory and encode
  them.

## Verbs

| Command | Args | Result |
|---|---|---|
| `hello` | | `{app, name, hudkit, version, panels, verbs}`: `hudkit` is the contract version, `version` the app's (`VERSION`) |
| `state` | | `{panels: [{id: "tools", visible, mode, badge?, status?}]}`: `badge` is the number of running jobs (absent when none); `status` is `"2 running, 1 waiting"` while jobs run, else the dropped file's name |
| `subscribe` | `events=state` (optional) | `{"event": "state", "panels": [...]}` when visibility, mode, frame, the dropped file or the job list changes. Progress ticks are not pushed; poll `action jobs` for them. `ffmpeghud watch` prints events. |
| `panel show` / `hide` / `toggle` | `id=tools`, optional `from=`/`to=<edge>`, `anchor=x,y,w,h`, `reason=hover\|click\|summon` | fades in or out at the last frame and mode, without taking focus; with `from=`/`to=` slides out of / back into the dock (see Hover above) |
| `panel frame` | `id=tools x= y= w= h=` | AppKit screen coordinates; kept as the frame for the current mode |
| `panel mode` | `id=tools` + `full`, `compact` or `parked` | `compact` is the 44 pt drop tile (glyph, running-jobs badge, progress ring; a click or a drop returns to full); `parked` slides to the nearest screen edge leaving a 14 pt sliver, or to `edge=` with a `peek=` sliver when given (remembered) |
| `settings get` / `set` / `schema` | | see Settings |
| `action drop` | `paths=` pipe-separated, each path percent-encoded; or `path=` one raw path; `show=0` (optional) | makes the files the panel's input and probes them. `file://` segments are accepted. Folders and missing files are skipped (an error if nothing is left). Shows the panel (switching the tile back to full) unless `show=0`. Returns `{files: [...]}` |
| `action run` | `preset=`, `input=` (a path) and/or `inputs=` (encoded like `paths=`), any preset field as `field=value`, `output=` (optional; must not exist), `show=1` (optional) | queues a job; without `input=`/`inputs=` it runs on the dropped file(s). Unknown fields are ignored; invalid values (a bad time, a choice that is not one, an encoder this ffmpeg lacks) are refused. Returns `{job: {...}}` at once; poll `jobs` (or `ffmpeghud run ... wait=1`) |
| `action jobs` | `id=` (optional) | `{running, count, jobs: [...]}`, newest first |
| `action cancel` | `id=` or `all=1` | stops a queued or running job (SIGINT, then SIGTERM after 2 s); its partial output is removed |
| `action presets` | | `{presets: [...], input?: {path, info}}`, recent first |
| `action snapshot` | `path=` | writes a PNG of the panel as it is now |
| `action show` / `hide` / `toggle` | | same as the panel verbs |
| `quit` | | replies, then quits: running jobs are cancelled (partial outputs removed), the socket file is removed |

A job is `{id, preset, title, inputs, output, state, argv, written, progress?, duration?,
error?, trashedOriginal?, created, started?, finished?}`: `state` is `queued`, `running`,
`succeeded`, `failed` or `cancelled`; `progress` is 0-1 when the output's length is known;
`written` is seconds of output so far; `error` holds ffmpeg's last lines.

A preset is `{id, title, summary, symbol, needsVideo, multiInput, fields: [{id, label, kind,
default, options?, placeholder?}]}`. Preset ids: `convert compress resize trim gif audio mute
speed thumbnail concat rotate crop web remux normalize`.

### Drop encoding

`paths=` joins the paths with `|`; each path is percent-encoded first, so `|`, `%`, `=`,
spaces, newlines and non-ASCII names survive the socket and the CLI's `key=value` parsing.
This is the encoding of HUDKit's `HUDDrop` (which escapes everything but ASCII letters,
digits and `/-._~`); ffmpegHUD's own encoder escapes a little less (it keeps other
path-safe punctuation) and its decoder reads both.

```
action drop paths=/Users/me/Movies/Screen%20Recording%E2%80%AFAM.mov|/Users/me/a%7Cb.mp4
```

## Commands ffmpegHUD runs

Always an argv, never a shell: `ffmpeg -hide_banner -nostdin -n <input options> -i <input>
<preset args> <output>` (`-n`: ffmpeg refuses to overwrite, a second guard behind the naming
rules). Join clips uses the concat demuxer with a list file in the temp directory. As a
job starts, `ffprobe -v error -print_format json -show_format -show_streams <input>` gives the
duration for the progress fraction (skipped when the drop zone already probed the file).

## Settings

`Sources/ffmpegHUD/Resources/settings.json` describes them for MacHUD's shared settings window. Values are
stored in `<home>/preferences.json`, where home is `~/Library/Application Support/ffmpegHUD`
or `$FFMPEGHUD_HOME`.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `output.folder` | `same` / `movies` / `custom` | `same` | where results go: the original's folder, `~/Movies`, or `output.customFolder` |
| `output.customFolder` | path | `""` | required when `output.folder` is `custom` |
| `naming.suffix` | string | `_{preset}` | added to the original's name; `{preset}` is the preset's word (`gif`, `compressed`, `trimmed`...); no `/` or `:` |
| `keepOriginal` | bool | `true` | off: the original is moved to the Trash after its job succeeds (not while another job still needs it) |
| `jobs.concurrent` | int (1-8) | `2` | jobs run at once |

## Menu bar consolidation

While MacHUD runs it shows ffmpegHUD's status menu inside its own (`menu`, `menu-invoke`) and
the menu bar icon hides; it comes back when MacHUD quits or the user turns the
`menuBar.consumed` setting off (served by HUDKit's router, default `true`). The setting is
kept in `<home>/menubar.json` (so `FFMPEGHUD_HOME` isolates it), never in the user's real preferences from a test instance.
See [menu bar consolidation](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#menu-bar-consolidation).

## Environment

| Variable | Read by | Effect |
|---|---|---|
| `FFMPEGHUD_HOME` | app | base directory for preferences; also keeps panel frames and recent presets apart from the real instance's |
| `FFMPEGHUD_SOCKET` | app, CLI | socket name instead of `ffmpeghud` |
| `FFMPEGHUD_NO_HOTKEYS` | app | skip the global hotkey |

Together they let a second instance run beside the real one:

```sh
FFMPEGHUD_HOME=/tmp/ffmpeghud-test FFMPEGHUD_SOCKET=ffmpeghud-test FFMPEGHUD_NO_HOTKEYS=1 \
  build/ffmpegHUD.app/Contents/MacOS/ffmpegHUD &
FFMPEGHUD_SOCKET=ffmpeghud-test build/ffmpegHUD.app/Contents/Helpers/ffmpeghud drop /tmp/clip.mp4
FFMPEGHUD_SOCKET=ffmpeghud-test build/ffmpegHUD.app/Contents/Helpers/ffmpeghud quit
```

## Launch flags

| Flag | Effect |
|---|---|
| `--snapshot <path.png>` | writes a PNG of the panel after it settles (the glass drawn as a dark stand-in); the app keeps running |
| `--snapshot-mode compact` | pictures the compact tile instead |
| `--snapshot-delay <s>` | waits `s` seconds before the snapshot (default 2) |
| `--drop <path>` | starts with that file dropped |
| `--preset <id>` | starts on that preset |
| `--run` | runs the preset on the dropped file |
