@testable import ffmpegHUDKit
import XCTest

/// Every preset's argv with its prefilled values, plus the variants that change shape.
final class CommandBuilderTests: XCTestCase {
    let input = "/tmp/in/clip.mov"
    let output = "/tmp/out/result.ext"
    let prefix = ["ffmpeg", "-hide_banner", "-nostdin", "-n"]

    private func argv(_ preset: Preset, _ overrides: [String: String] = [:], inputs: [String]? = nil,
                      file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let values = PresetValues(preset: preset).applying(overrides, preset: preset)
        return try CommandBuilder.build(preset, values: values, inputs: inputs ?? [input], output: output,
                                        listFile: "/tmp/list.txt").argv
    }

    /// Default argv per preset id. A preset added to the catalog without an entry here fails.
    var expected: [String: [String]] {
        let i = input, o = output
        return [
            "convert": ["-i", i, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", o],
            "compress": ["-i", i, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23", "-preset", "medium",
                         "-c:a", "aac", "-b:a", "128k", o],
            "resize": ["-i", i, "-vf", "scale=1280:-2", "-c:a", "copy", o],
            "trim": ["-ss", "00:00:00", "-i", i, "-t", "00:00:10", o],
            "gif": ["-i", i, "-vf", "fps=15,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                    "-loop", "0", o],
            "audio": ["-i", i, "-vn", "-c:a", "libmp3lame", "-b:a", "192k", o],
            "mute": ["-i", i, "-c:v", "copy", "-an", o],
            "speed": ["-i", i, "-filter:v", "setpts=PTS/2", "-filter:a", "atempo=2.0", o],
            "thumbnail": ["-ss", "00:00:01", "-i", i, "-frames:v", "1", "-vf", "scale=1280:-2", "-q:v", "2", "-update", "1", o],
            "concat": ["-f", "concat", "-safe", "0", "-i", "/tmp/list.txt", "-c", "copy", o],
            "rotate": ["-i", i, "-vf", "transpose=1", "-c:a", "copy", o],
            "crop": ["-i", i, "-vf", "crop=trunc(min(iw\\,ih*1/1)/2)*2:trunc(min(ih\\,iw*1/1)/2)*2", "-c:a", "copy", o],
            "web": ["-i", i, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23", "-preset", "medium",
                    "-movflags", "+faststart", "-c:a", "aac", "-b:a", "128k", o],
            "remux": ["-i", i, "-c", "copy", o],
            "normalize": ["-i", i, "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-c:v", "copy", o],
        ]
    }

    func testEveryPresetDefaultArgv() throws {
        XCTAssertEqual(Set(PresetCatalog.all.map(\.id)), Set(expected.keys), "every preset has an expected argv")
        for preset in PresetCatalog.all {
            XCTAssertEqual(try argv(preset), prefix + expected[preset.id]!, preset.id)
        }
    }

    func testPresetIDsAreUniqueAndDefaultsValid() throws {
        XCTAssertEqual(Set(PresetCatalog.all.map(\.id)).count, PresetCatalog.all.count)
        for preset in PresetCatalog.all {
            XCTAssertNoThrow(try CommandBuilder.validate(preset, values: PresetValues(preset: preset)), preset.id)
            for field in preset.fields where field.kind == .select {
                XCTAssertNotNil(field.option(field.defaultValue), "\(preset.id).\(field.id) default is a choice")
            }
        }
    }

    func testNeverAShellString() throws {
        // A path with spaces, quotes and shell metacharacters stays one argv element.
        let nasty = "/tmp/in/my clip; rm -rf ~ 'x' $(y).mov"
        let preset = PresetCatalog.mute
        let command = try CommandBuilder.build(preset, values: PresetValues(preset: preset), inputs: [nasty], output: output)
        XCTAssertEqual(command.argv, prefix + ["-i", nasty, "-c:v", "copy", "-an", output])
        XCTAssertTrue(command.display.contains("'/tmp/in/my clip; rm -rf ~ '\\''x'\\'' $(y).mov'"))
        let resolved = Command(argv: ["/opt/homebrew/bin/ffmpeg", "-i", "/a b.mov"], output: "/o", listFile: nil)
        XCTAssertEqual(resolved.display, "ffmpeg -i '/a b.mov'")
    }

    func testConvertFormats() throws {
        XCTAssertEqual(try argv(PresetCatalog.convert, ["format": "webm"]),
                       prefix + ["-i", input, "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-c:a", "libopus", output])
        XCTAssertEqual(try argv(PresetCatalog.convert, ["format": "avi"]),
                       prefix + ["-i", input, "-c:v", "mpeg4", "-q:v", "5", "-c:a", "libmp3lame", output])
    }

    func testCompressHEVCAndQuality() throws {
        XCTAssertEqual(try argv(PresetCatalog.compress, ["codec": "h265", "crf": "28", "speed": "slow"]),
                       prefix + ["-i", input, "-c:v", "libx265", "-pix_fmt", "yuv420p", "-tag:v", "hvc1", "-crf", "28",
                                 "-preset", "slow", "-c:a", "aac", "-b:a", "128k", output])
    }

    func testResizeCustomAndHalf() throws {
        XCTAssertEqual(try argv(PresetCatalog.resize, ["resolution": "custom", "custom": "640:360"]),
                       prefix + ["-i", input, "-vf", "scale=640:360", "-c:a", "copy", output])
        XCTAssertEqual(try argv(PresetCatalog.resize, ["resolution": "half"]),
                       prefix + ["-i", input, "-vf", "scale=trunc(iw/4)*2:-2", "-c:a", "copy", output])
        XCTAssertThrowsError(try argv(PresetCatalog.resize, ["resolution": "custom"])) {
            XCTAssertEqual($0 as? CommandError, .invalid(field: "custom", reason: "required"))
        }
        XCTAssertThrowsError(try argv(PresetCatalog.resize, ["resolution": "custom", "custom": "big"]))
        // The custom field is ignored (and not validated) unless Custom is chosen.
        XCTAssertNoThrow(try argv(PresetCatalog.resize, ["custom": "junk"]))
    }

    func testTrimVariants() throws {
        XCTAssertEqual(try argv(PresetCatalog.trim, ["start": "", "duration": "", "mode": "copy"]),
                       prefix + ["-i", input, "-c", "copy", output])
        XCTAssertEqual(try argv(PresetCatalog.trim, ["start": "65.5", "duration": "1:00"]),
                       prefix + ["-ss", "65.5", "-i", input, "-t", "1:00", output])
        XCTAssertThrowsError(try argv(PresetCatalog.trim, ["start": "soon"])) {
            XCTAssertEqual($0 as? CommandError, .invalid(field: "start", reason: "soon is not a time (00:00:05 or 5)"))
        }
    }

    func testGifWithRange() throws {
        XCTAssertEqual(try argv(PresetCatalog.gif, ["start": "2", "duration": "3", "fps": "10", "width": "320"]),
                       prefix + ["-ss", "2", "-i", input, "-t", "3", "-vf",
                                 "fps=10,scale=320:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                                 "-loop", "0", output])
    }

    func testAudioFormats() throws {
        XCTAssertEqual(try argv(PresetCatalog.audio, ["format": "m4a", "bitrate": "320k"]),
                       prefix + ["-i", input, "-vn", "-c:a", "aac", "-b:a", "320k", output])
        XCTAssertEqual(try argv(PresetCatalog.audio, ["format": "wav"]), prefix + ["-i", input, "-vn", "-c:a", "pcm_s16le", output])
        XCTAssertEqual(try argv(PresetCatalog.audio, ["format": "flac"]), prefix + ["-i", input, "-vn", "-c:a", "flac", output])
        XCTAssertEqual(try argv(PresetCatalog.audio, ["format": "opus", "bitrate": "128k"]),
                       prefix + ["-i", input, "-vn", "-c:a", "libopus", "-b:a", "128k", output])
    }

    func testSpeedExtremesChainAtempo() throws {
        XCTAssertEqual(try argv(PresetCatalog.speed, ["factor": "4"]),
                       prefix + ["-i", input, "-filter:v", "setpts=PTS/4", "-filter:a", "atempo=2.0,atempo=2.0", output])
        XCTAssertEqual(try argv(PresetCatalog.speed, ["factor": "0.25"]),
                       prefix + ["-i", input, "-filter:v", "setpts=PTS/0.25", "-filter:a", "atempo=0.5,atempo=0.5", output])
    }

    func testThumbnailPNGOriginalSize() throws {
        XCTAssertEqual(try argv(PresetCatalog.thumbnail, ["width": "original", "format": "png", "at": "12"]),
                       prefix + ["-ss", "12", "-i", input, "-frames:v", "1", "-update", "1", output])
    }

    func testConcatListFile() throws {
        let preset = PresetCatalog.concat
        let command = try CommandBuilder.build(preset, values: PresetValues(preset: preset),
                                               inputs: ["/a/one.mp4", "/a/it's two.mp4"], output: output, listFile: "/tmp/l.txt")
        XCTAssertEqual(command.listFile?.path, "/tmp/l.txt")
        XCTAssertEqual(command.listFile?.contents, "file '/a/one.mp4'\nfile '/a/it'\\''s two.mp4'\n")
        XCTAssertThrowsError(try argv(PresetCatalog.mute, inputs: ["/a", "/b"])) {
            XCTAssertEqual($0 as? CommandError, .tooManyInputs("Remove audio"))
        }
    }

    func testRotateAndCropChoices() throws {
        XCTAssertEqual(try argv(PresetCatalog.rotate, ["rotation": "180"]),
                       prefix + ["-i", input, "-vf", "transpose=1,transpose=1", "-c:a", "copy", output])
        XCTAssertEqual(try argv(PresetCatalog.crop, ["aspect": "9:16"])[7],
                       "crop=trunc(min(iw\\,ih*9/16)/2)*2:trunc(min(ih\\,iw*16/9)/2)*2")
    }

    func testRemuxAndNormalizeChoices() throws {
        XCTAssertEqual(try argv(PresetCatalog.normalize, ["target": "-23"])[7], "loudnorm=I=-23:TP=-1.5:LRA=11")
        XCTAssertThrowsError(try argv(PresetCatalog.remux, ["format": "exe"])) {
            XCTAssertEqual($0 as? CommandError, .unknownOption(field: "format", value: "exe"))
        }
    }

    func testEncoderCheck() throws {
        let preset = PresetCatalog.convert
        let webm = PresetValues(preset: preset).applying(["format": "webm"], preset: preset)
        XCTAssertThrowsError(try CommandBuilder.build(preset, values: webm, inputs: [input], output: output,
                                                      encoders: ["libx264", "aac", "libopus"])) {
            XCTAssertEqual($0 as? CommandError, .missingEncoder("libvpx-vp9"))
        }
        XCTAssertNoThrow(try CommandBuilder.build(preset, values: webm, inputs: [input], output: output,
                                                  encoders: ["libvpx-vp9", "libopus"]))
        XCTAssertEqual(Encoders.required(by: ["ffmpeg", "-c", "copy", "-c:v", "libx264", "-codec:a", "aac", "-c:a", "aac"]),
                       ["libx264", "aac"])
        XCTAssertEqual(Encoders.required(by: preset.field("format")!.option("webm")!), ["libvpx-vp9", "libopus"])
        let listing = """
        Encoders:
         V..... = Video
         ------
         V....D libx264              libx264 H.264 / AVC
         A....D aac                  AAC (Advanced Audio Coding)
        """
        XCTAssertEqual(Encoders.parse(listing), ["libx264", "aac"])
    }

    func testNoInput() {
        XCTAssertThrowsError(try argv(PresetCatalog.gif, inputs: [])) { XCTAssertEqual($0 as? CommandError, .noInput) }
    }

    func testTokenSubstitution() {
        let tokens = CommandBuilder.tokens(preset: PresetCatalog.gif, values: PresetValues(preset: PresetCatalog.gif),
                                           input: "/Users/me/Movies/Holiday 2026.MOV", output: "/o/x.gif")
        XCTAssertEqual(tokens["dir"], "/Users/me/Movies")
        XCTAssertEqual(tokens["name"], "Holiday 2026")
        XCTAssertEqual(tokens["ext"], "MOV")
        XCTAssertEqual(CommandBuilder.substitute("{dir}/{name}_{fps}.{ext} {output} {unknown}", tokens),
                       "/Users/me/Movies/Holiday 2026_15.MOV /o/x.gif {unknown}")
        XCTAssertEqual(CommandBuilder.substitute("no tokens", tokens), "no tokens")
        XCTAssertEqual(CommandBuilder.substitute("dangling {input", tokens), "dangling {input")
    }

    func testValuesIgnoreUnknownKeys() {
        let preset = PresetCatalog.gif
        let values = PresetValues(preset: preset).applying(["fps": "24", "input": "/x", "preset": "gif"], preset: preset)
        XCTAssertEqual(values["fps"], "24")
        XCTAssertEqual(values.values["input"], nil)
    }

    func testTimeFormat() {
        XCTAssertEqual(TimeFormat.seconds("5"), 5)
        XCTAssertEqual(TimeFormat.seconds("1.5"), 1.5)
        XCTAssertEqual(TimeFormat.seconds("01:05"), 65)
        XCTAssertEqual(TimeFormat.seconds("1:02:03.25"), 3723.25)
        XCTAssertNil(TimeFormat.seconds(""))
        XCTAssertNil(TimeFormat.seconds("abc"))
        XCTAssertNil(TimeFormat.seconds("-3"))
        XCTAssertNil(TimeFormat.seconds("1:75"))
        XCTAssertNil(TimeFormat.seconds("1:2:3:4"))
        XCTAssertEqual(TimeFormat.clock(83.4), "1:23")
        XCTAssertEqual(TimeFormat.clock(3723), "1:02:03")
    }
}
