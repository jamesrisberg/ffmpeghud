import Foundation

/// The built-in presets: convert, compress, resize, trim, gif, extract audio, remove audio,
/// speed, thumbnail, concat, rotate, crop, web-optimised MP4, remux and loudness normalisation.
///
/// Filter expressions are single argv elements, never shell text: a comma inside an
/// expression is escaped for ffmpeg's filtergraph parser (`min(iw\,ih)`), not for a shell.
public enum PresetCatalog {
    public static let all: [Preset] = [
        convert, compress, resize, trim, gif, audio, mute, speed, thumbnail, concat, rotate, crop, web, remux, normalize,
    ]

    public static func preset(_ id: String) -> Preset? { all.first { $0.id == id } }

    // MARK: - Presets

    public static let convert = Preset(
        id: "convert", title: "Convert format", summary: "Re-encode into another container and codec",
        symbol: "arrow.triangle.2.circlepath", suffix: "converted",
        fields: [
            .select("format", "Output format", [
                PresetOption("MP4 (H.264)", "mp4", args: ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
                PresetOption("WebM (VP9)", "webm", args: ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-c:a", "libopus"]),
                PresetOption("MOV (H.264)", "mov", args: ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
                PresetOption("MKV (H.264)", "mkv", args: ["-c:v", "libx264", "-c:a", "aac"]),
                PresetOption("AVI (MPEG-4)", "avi", args: ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "libmp3lame"]),
            ]),
        ],
        args: [.option("format")],
        output: .field("format"))

    public static let compress = Preset(
        id: "compress", title: "Compress", summary: "Smaller file at a chosen quality (CRF)",
        symbol: "arrow.down.right.and.arrow.up.left", suffix: "compressed",
        fields: [
            .select("codec", "Codec", [
                PresetOption("H.264 (plays everywhere)", "h264", args: ["-c:v", "libx264", "-pix_fmt", "yuv420p"]),
                PresetOption("H.265 / HEVC (smaller)", "h265", args: ["-c:v", "libx265", "-pix_fmt", "yuv420p", "-tag:v", "hvc1"]),
            ]),
            .select("crf", "Quality", [
                PresetOption("High (CRF 18)", "18"),
                PresetOption("Good (CRF 23)", "23"),
                PresetOption("Medium (CRF 28)", "28"),
                PresetOption("Small (CRF 32)", "32"),
            ], default: "23"),
            .select("speed", "Encoding speed", [
                PresetOption("Fast", "fast"),
                PresetOption("Medium", "medium"),
                PresetOption("Slow (smaller)", "slow"),
            ], default: "medium"),
        ],
        args: [.option("codec"), .arg("-crf"), .arg("{crf}"), .arg("-preset"), .arg("{speed}"),
               .arg("-c:a"), .arg("aac"), .arg("-b:a"), .arg("128k")],
        output: .fixed("mp4"))

    public static let resize = Preset(
        id: "resize", title: "Resize", summary: "Scale to a width, keeping the aspect ratio",
        symbol: "arrow.up.left.and.arrow.down.right", suffix: "resized",
        fields: [
            .select("resolution", "Resolution", [
                PresetOption("4K (3840 wide)", "3840", args: ["-vf", "scale=3840:-2"]),
                PresetOption("1080p (1920 wide)", "1920", args: ["-vf", "scale=1920:-2"]),
                PresetOption("720p (1280 wide)", "1280", args: ["-vf", "scale=1280:-2"]),
                PresetOption("480p (854 wide)", "854", args: ["-vf", "scale=854:-2"]),
                PresetOption("Half size", "half", args: ["-vf", "scale=trunc(iw/4)*2:-2"]),
                PresetOption("Custom", "custom", args: ["-vf", "scale={custom}"]),
            ], default: "1280"),
            .text("custom", "Custom size", placeholder: "width:height (-2 keeps the ratio)", required: true,
                  format: .size, visibleWhen: ("resolution", ["custom"])),
        ],
        args: [.option("resolution"), .arg("-c:a"), .arg("copy")],
        output: .input(fallback: "mp4"))

    public static let trim = Preset(
        id: "trim", title: "Trim", summary: "Cut a section by start time and duration",
        symbol: "scissors", suffix: "trimmed",
        fields: [
            .text("start", "Start", default: "00:00:00", placeholder: "00:00:00 or seconds", format: .time),
            .text("duration", "Duration", default: "00:00:10", placeholder: "00:00:30 or seconds", format: .time),
            .select("mode", "Cut", [
                PresetOption("Exact (re-encode)", "exact"),
                PresetOption("Fast (copy, cuts at keyframes)", "copy", args: ["-c", "copy"]),
            ]),
        ],
        inputArgs: [.when("start", ["-ss", "{start}"])],
        args: [.when("duration", ["-t", "{duration}"]), .option("mode")],
        output: .input(fallback: "mp4"),
        needsVideo: false)

    public static let gif = Preset(
        id: "gif", title: "Make a GIF", summary: "Palette-optimised animated GIF",
        symbol: "photo.stack", suffix: "gif",
        fields: [
            .select("fps", "Frame rate", [
                PresetOption("10 fps", "10"), PresetOption("15 fps", "15"), PresetOption("24 fps", "24"),
            ], default: "15"),
            .select("width", "Width", [
                PresetOption("320 px", "320"), PresetOption("480 px", "480"),
                PresetOption("640 px", "640"), PresetOption("800 px", "800"),
            ], default: "480"),
            .text("start", "Start", placeholder: "optional, 00:00:05", format: .time),
            .text("duration", "Duration", placeholder: "optional, 00:00:05", format: .time),
        ],
        inputArgs: [.when("start", ["-ss", "{start}"])],
        args: [.when("duration", ["-t", "{duration}"]),
               .arg("-vf"), .arg("fps={fps},scale={width}:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"),
               .arg("-loop"), .arg("0")],
        output: .fixed("gif"))

    public static let audio = Preset(
        id: "audio", title: "Extract audio", summary: "Keep only the sound, as its own file",
        symbol: "waveform", suffix: "audio",
        fields: [
            .select("format", "Audio format", [
                PresetOption("MP3", "mp3", args: ["-c:a", "libmp3lame", "-b:a", "{bitrate}"]),
                PresetOption("AAC (.m4a)", "m4a", args: ["-c:a", "aac", "-b:a", "{bitrate}"]),
                PresetOption("WAV", "wav", args: ["-c:a", "pcm_s16le"]),
                PresetOption("FLAC", "flac", args: ["-c:a", "flac"]),
                PresetOption("Opus", "opus", args: ["-c:a", "libopus", "-b:a", "{bitrate}"]),
            ]),
            .select("bitrate", "Bitrate", [
                PresetOption("High (320k)", "320k"), PresetOption("Good (192k)", "192k"), PresetOption("Medium (128k)", "128k"),
            ], default: "192k"),
        ],
        args: [.arg("-vn"), .option("format")],
        output: .field("format"),
        needsVideo: false)

    public static let mute = Preset(
        id: "mute", title: "Remove audio", summary: "Silent copy; the picture is not re-encoded",
        symbol: "speaker.slash", suffix: "muted",
        args: [.arg("-c:v"), .arg("copy"), .arg("-an")],
        output: .input(fallback: "mp4"))

    public static let speed = Preset(
        id: "speed", title: "Change speed", summary: "Faster or slower, picture and sound together",
        symbol: "gauge.with.dots.needle.67percent", suffix: "speed",
        fields: [
            .select("factor", "Speed", [
                PresetOption("0.25x", "0.25", args: ["-filter:v", "setpts=PTS/0.25", "-filter:a", "atempo=0.5,atempo=0.5"]),
                PresetOption("0.5x", "0.5", args: ["-filter:v", "setpts=PTS/0.5", "-filter:a", "atempo=0.5"]),
                PresetOption("1.5x", "1.5", args: ["-filter:v", "setpts=PTS/1.5", "-filter:a", "atempo=1.5"]),
                PresetOption("2x", "2", args: ["-filter:v", "setpts=PTS/2", "-filter:a", "atempo=2.0"]),
                PresetOption("4x", "4", args: ["-filter:v", "setpts=PTS/4", "-filter:a", "atempo=2.0,atempo=2.0"]),
            ], default: "2"),
        ],
        args: [.option("factor")],
        output: .input(fallback: "mp4"),
        needsVideo: false)

    public static let thumbnail = Preset(
        id: "thumbnail", title: "Thumbnail", summary: "One frame as an image",
        symbol: "photo", suffix: "thumb",
        fields: [
            .text("at", "At", default: "00:00:01", placeholder: "00:00:01 or seconds", format: .time),
            .select("width", "Width", [
                PresetOption("Original", "original"),
                PresetOption("1280 px", "1280", args: ["-vf", "scale=1280:-2"]),
                PresetOption("640 px", "640", args: ["-vf", "scale=640:-2"]),
                PresetOption("320 px", "320", args: ["-vf", "scale=320:-2"]),
            ], default: "1280"),
            .select("format", "Image format", [
                PresetOption("JPEG", "jpg", args: ["-q:v", "2"]),
                PresetOption("PNG", "png"),
            ]),
        ],
        inputArgs: [.when("at", ["-ss", "{at}"])],
        args: [.arg("-frames:v"), .arg("1"), .option("width"), .option("format"), .arg("-update"), .arg("1")],
        output: .field("format"))

    public static let concat = Preset(
        id: "concat", title: "Join clips", summary: "Concatenate the dropped files in order",
        symbol: "rectangle.stack.badge.plus", suffix: "joined",
        fields: [
            .select("mode", "Join", [
                PresetOption("Fast (copy; same codecs and size)", "copy", args: ["-c", "copy"]),
                PresetOption("Re-encode (mixed sources)", "encode", args: ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
            ]),
        ],
        args: [.option("mode")],
        output: .input(fallback: "mp4"),
        needsVideo: false,
        multiInput: true)

    public static let rotate = Preset(
        id: "rotate", title: "Rotate / flip", summary: "Turn or mirror the picture",
        symbol: "rotate.right", suffix: "rotated",
        fields: [
            .select("rotation", "Rotation", [
                PresetOption("90° clockwise", "90", args: ["-vf", "transpose=1"]),
                PresetOption("90° counter-clockwise", "-90", args: ["-vf", "transpose=2"]),
                PresetOption("180°", "180", args: ["-vf", "transpose=1,transpose=1"]),
                PresetOption("Flip horizontal", "hflip", args: ["-vf", "hflip"]),
                PresetOption("Flip vertical", "vflip", args: ["-vf", "vflip"]),
            ]),
        ],
        args: [.option("rotation"), .arg("-c:a"), .arg("copy")],
        output: .input(fallback: "mp4"))

    public static let crop = Preset(
        id: "crop", title: "Crop to aspect", summary: "Centre crop to square, vertical or widescreen",
        symbol: "crop", suffix: "cropped",
        fields: [
            .select("aspect", "Aspect", [
                PresetOption("Square (1:1)", "1:1", args: ["-vf", cropFilter(1, 1)]),
                PresetOption("Vertical (9:16)", "9:16", args: ["-vf", cropFilter(9, 16)]),
                PresetOption("Widescreen (16:9)", "16:9", args: ["-vf", cropFilter(16, 9)]),
                PresetOption("Standard (4:3)", "4:3", args: ["-vf", cropFilter(4, 3)]),
            ]),
        ],
        args: [.option("aspect"), .arg("-c:a"), .arg("copy")],
        output: .input(fallback: "mp4"))

    public static let web = Preset(
        id: "web", title: "Web-ready MP4", summary: "H.264, yuv420p, fast start: plays in every browser",
        symbol: "globe", suffix: "web",
        fields: [
            .select("crf", "Quality", [
                PresetOption("High (CRF 20)", "20"), PresetOption("Good (CRF 23)", "23"), PresetOption("Small (CRF 28)", "28"),
            ], default: "23"),
        ],
        args: [.arg("-c:v"), .arg("libx264"), .arg("-pix_fmt"), .arg("yuv420p"), .arg("-crf"), .arg("{crf}"),
               .arg("-preset"), .arg("medium"), .arg("-movflags"), .arg("+faststart"),
               .arg("-c:a"), .arg("aac"), .arg("-b:a"), .arg("128k")],
        output: .fixed("mp4"))

    public static let remux = Preset(
        id: "remux", title: "Change container", summary: "Rewrap without re-encoding (instant, lossless)",
        symbol: "shippingbox", suffix: "remux",
        fields: [
            .select("format", "Container", [
                PresetOption("MP4", "mp4"), PresetOption("MKV", "mkv"), PresetOption("MOV", "mov"),
            ]),
        ],
        args: [.arg("-c"), .arg("copy")],
        output: .field("format"),
        needsVideo: false)

    public static let normalize = Preset(
        id: "normalize", title: "Normalize loudness", summary: "Even out audio loudness (EBU R128)",
        symbol: "speaker.wave.2", suffix: "normalized",
        fields: [
            .select("target", "Target", [
                PresetOption("Podcast / web (-16 LUFS)", "-16"),
                PresetOption("Streaming (-14 LUFS)", "-14"),
                PresetOption("Broadcast (-23 LUFS)", "-23"),
            ]),
        ],
        args: [.arg("-af"), .arg("loudnorm=I={target}:TP=-1.5:LRA=11"), .arg("-c:v"), .arg("copy")],
        output: .input(fallback: "mp4"),
        needsVideo: false)

    /// Largest centred `w:h` crop, rounded down to even sizes.
    static func cropFilter(_ w: Int, _ h: Int) -> String {
        "crop=trunc(min(iw\\,ih*\(w)/\(h))/2)*2:trunc(min(ih\\,iw*\(h)/\(w))/2)*2"
    }
}
