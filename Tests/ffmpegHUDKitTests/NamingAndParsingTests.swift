@testable import ffmpegHUDKit
import XCTest

final class OutputNamingTests: XCTestCase {
    private func name(_ preset: Preset, _ overrides: [String: String] = [:], input: String = "/v/Holiday.MOV",
                      settings: FFmpegSettings = FFmpegSettings(), taken: Set<String> = []) -> String {
        let values = PresetValues(preset: preset).applying(overrides, preset: preset)
        return OutputNaming.output(for: [input], preset: preset, values: values, settings: settings,
                                   moviesFolder: "/Users/me/Movies", isTaken: { taken.contains($0) })
    }

    func testSameFolderWithPresetSuffixAndExtensionRules() {
        XCTAssertEqual(name(PresetCatalog.gif), "/v/Holiday_gif.gif")
        XCTAssertEqual(name(PresetCatalog.compress), "/v/Holiday_compressed.mp4")
        XCTAssertEqual(name(PresetCatalog.mute), "/v/Holiday_muted.mov", "keeps the input's extension, lowercased")
        XCTAssertEqual(name(PresetCatalog.mute, input: "/v/noext"), "/v/noext_muted.mp4")
        XCTAssertEqual(name(PresetCatalog.audio, ["format": "flac"]), "/v/Holiday_audio.flac")
        XCTAssertEqual(name(PresetCatalog.thumbnail, ["format": "png"]), "/v/Holiday_thumb.png")
        XCTAssertEqual(name(PresetCatalog.convert, ["format": "webm"]), "/v/Holiday_converted.webm")
    }

    func testNeverOverwrites() {
        XCTAssertEqual(name(PresetCatalog.gif, taken: ["/v/Holiday_gif.gif"]), "/v/Holiday_gif-2.gif")
        XCTAssertEqual(name(PresetCatalog.gif, taken: ["/v/Holiday_gif.gif", "/v/Holiday_gif-2.gif"]), "/v/Holiday_gif-3.gif")
    }

    func testNeverWritesOverTheInput() {
        var settings = FFmpegSettings()
        settings.namingSuffix = ""
        XCTAssertEqual(name(PresetCatalog.mute, input: "/v/a.mov", settings: settings), "/v/a-2.mov")
        XCTAssertEqual(name(PresetCatalog.gif, input: "/v/a.mov", settings: settings), "/v/a.gif")
    }

    func testFolders() {
        var settings = FFmpegSettings()
        settings.outputFolder = .movies
        XCTAssertEqual(name(PresetCatalog.gif, settings: settings), "/Users/me/Movies/Holiday_gif.gif")
        settings.outputFolder = .custom
        settings.customFolder = "/Volumes/Out"
        XCTAssertEqual(name(PresetCatalog.gif, settings: settings), "/Volumes/Out/Holiday_gif.gif")
        settings.customFolder = "~/Exports"
        XCTAssertEqual(name(PresetCatalog.gif, settings: settings), NSHomeDirectory() + "/Exports/Holiday_gif.gif")
    }

    func testCustomSuffix() {
        var settings = FFmpegSettings()
        settings.namingSuffix = " ({preset})"
        XCTAssertEqual(name(PresetCatalog.trim, settings: settings), "/v/Holiday (trimmed).mov")
        settings.namingSuffix = "-ffmpeg"
        XCTAssertEqual(name(PresetCatalog.trim, settings: settings), "/v/Holiday-ffmpeg.mov")
    }

    func testConcatNamedAfterTheFirstInput() {
        let preset = PresetCatalog.concat
        XCTAssertEqual(OutputNaming.output(for: ["/v/a.mp4", "/v/b.mp4"], preset: preset, values: PresetValues(preset: preset),
                                           settings: FFmpegSettings(), isTaken: { _ in false }), "/v/a_joined.mp4")
    }

    func testOneUndecodableValueKeepsTheOtherSavedSettings() throws {
        let json = #"{"jobs.concurrent": "two", "keepOriginal": false, "naming.suffix": "_z"}"#
        let s = try JSONDecoder().decode(FFmpegSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.concurrentJobs, FFmpegSettings().concurrentJobs)
        XCTAssertEqual(s.keepOriginal, false)
        XCTAssertEqual(s.namingSuffix, "_z")
    }
}

final class ProgressTests: XCTestCase {
    let status = "frame=   48 fps=0.0 q=-0.0 size=     256KiB time=00:00:01.60 bitrate=1310.7kbits/s speed=3.19x"

    func testParsesTimeAndSpeed() {
        XCTAssertEqual(ProgressParser.time(in: status)!, 1.6, accuracy: 0.0001)
        XCTAssertEqual(ProgressParser.speed(in: status)!, 3.19, accuracy: 0.0001)
        XCTAssertTrue(ProgressParser.isStatus(status))
        XCTAssertTrue(ProgressParser.isStatus("size=     512KiB time=00:01:02.50 bitrate= 67.1kbits/s speed=40x"))
        XCTAssertEqual(ProgressParser.time(in: "size=     512KiB time=00:01:02.50 bitrate= 67.1kbits/s")!, 62.5, accuracy: 0.0001)
    }

    func testIgnoresOtherLines() {
        XCTAssertNil(ProgressParser.time(in: "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mov':"))
        XCTAssertNil(ProgressParser.time(in: "frame=    0 fps=0.0 q=0.0 size=       0KiB time=N/A bitrate=N/A speed=N/A"))
        XCTAssertEqual(ProgressParser.time(in: "frame=1 time=-00:00:00.04 bitrate=N/A"), 0)
        XCTAssertFalse(ProgressParser.isStatus("  Duration: 00:00:02.00, start: 0.000000, bitrate: 94 kb/s"))
        XCTAssertNil(ProgressParser.speed(in: "speed=N/A"))
    }

    func testFraction() {
        XCTAssertEqual(ProgressParser.fraction(time: 5, expected: 10), 0.5)
        XCTAssertEqual(ProgressParser.fraction(time: 12, expected: 10), 1)
        XCTAssertNil(ProgressParser.fraction(time: 5, expected: nil))
        XCTAssertNil(ProgressParser.fraction(time: 5, expected: 0))
    }

    func testExpectedDurationFollowsTheForm() {
        let trim = PresetCatalog.trim
        func expected(_ preset: Preset, _ total: Double?, _ overrides: [String: String] = [:]) -> Double? {
            ProgressParser.expectedDuration(total: total, preset: preset,
                                            values: PresetValues(preset: preset).applying(overrides, preset: preset))
        }
        XCTAssertEqual(expected(trim, 60), 10, "default 10 s cut")
        XCTAssertEqual(expected(trim, 60, ["start": "55", "duration": "30"]), 5, "runs off the end")
        XCTAssertEqual(expected(trim, 60, ["start": "", "duration": ""]), 60)
        XCTAssertEqual(expected(trim, nil, ["duration": "7"]), 7)
        XCTAssertEqual(expected(PresetCatalog.speed, 60, ["factor": "4"]), 15)
        XCTAssertEqual(expected(PresetCatalog.speed, 60, ["factor": "0.5"]), 120)
        XCTAssertEqual(expected(PresetCatalog.gif, 60, ["start": "10"]), 50)
        XCTAssertEqual(expected(PresetCatalog.mute, 42), 42)
        XCTAssertNil(expected(PresetCatalog.thumbnail, 42), "one frame: indeterminate")
        XCTAssertNil(expected(PresetCatalog.mute, nil))
    }

    func testStderrSplitsOnCarriageReturns() {
        var pending = ""
        XCTAssertEqual(FFmpegProcess.split(&pending, "line one\nframe=1 time=00:00:00.04\rframe=2 time=00:0"),
                       ["line one", "frame=1 time=00:00:00.04"])
        XCTAssertEqual(pending, "frame=2 time=00:0")
        XCTAssertEqual(FFmpegProcess.split(&pending, "0:00.08\r\n"), ["frame=2 time=00:00:00.08"])
        XCTAssertEqual(pending, "")
    }

    func testErrorSummaryIsTheTail() {
        XCTAssertEqual(JobQueue.errorSummary([], status: 1), "ffmpeg exited with status 1")
        XCTAssertEqual(JobQueue.errorSummary(["a", "b", "c", "d", "e"], status: 1), "b\nc\nd\ne")
    }
}

final class MediaInfoTests: XCTestCase {
    func testParsesFFprobeJSON() throws {
        let json = """
        {"streams": [
          {"index": 0, "codec_name": "h264", "codec_type": "video", "width": 1920, "height": 1080, "duration": "12.5"},
          {"index": 1, "codec_name": "aac", "codec_type": "audio", "sample_rate": "48000"},
          {"index": 2, "codec_name": "mjpeg", "codec_type": "video", "width": 600, "height": 600, "disposition": {"attached_pic": 1}}
        ], "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "12.512000", "size": "4404019"}}
        """
        let info = try XCTUnwrap(MediaInfo.parse(ffprobeJSON: Data(json.utf8)))
        XCTAssertEqual(info.duration!, 12.512, accuracy: 0.0001)
        XCTAssertEqual(info.width, 1920)
        XCTAssertEqual(info.height, 1080)
        XCTAssertEqual(info.videoCodec, "h264")
        XCTAssertEqual(info.audioCodec, "aac")
        XCTAssertEqual(info.size, 4_404_019)
        XCTAssertTrue(info.summary.hasPrefix("0:13 · 1920×1080 · h264 / aac · "))
    }

    func testAudioOnlyWithCoverArt() throws {
        let json = """
        {"streams": [
          {"codec_name": "mjpeg", "codec_type": "video", "width": 500, "height": 500, "disposition": {"attached_pic": 1}},
          {"codec_name": "mp3", "codec_type": "audio", "duration": "181.0"}
        ], "format": {"format_name": "mp3"}}
        """
        let info = try XCTUnwrap(MediaInfo.parse(ffprobeJSON: Data(json.utf8)))
        XCTAssertFalse(info.hasVideo)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.duration, 181)
        XCTAssertEqual(info.summary, "3:01 · mp3")
    }

    func testGarbage() {
        XCTAssertNil(MediaInfo.parse(ffprobeJSON: Data("not json".utf8)))
        XCTAssertEqual(MediaInfo.parse(ffprobeJSON: Data("{}".utf8))?.summary, "no audio or video streams")
    }
}

final class SettingsAndRecentsTests: XCTestCase {
    func testDefaultsAndValidation() throws {
        let d = FFmpegSettings()
        XCTAssertEqual(d.outputFolder, .same)
        XCTAssertEqual(d.namingSuffix, "_{preset}")
        XCTAssertTrue(d.keepOriginal)
        XCTAssertEqual(d.concurrentJobs, 2)
        let s = try d.applying(["output.folder": "movies", "keepOriginal": "false", "jobs.concurrent": "3", "naming.suffix": "-x"])
        XCTAssertEqual(s.outputFolder, .movies)
        XCTAssertFalse(s.keepOriginal)
        XCTAssertEqual(s.concurrentJobs, 3)
        XCTAssertEqual(s.namingSuffix, "-x")
        XCTAssertThrowsError(try d.applying(["output.folder": "desktop"]))
        XCTAssertThrowsError(try d.applying(["output.folder": "custom"]), "custom needs a folder")
        XCTAssertNoThrow(try d.applying(["output.folder": "custom", "output.customFolder": "/tmp"]))
        XCTAssertThrowsError(try d.applying(["jobs.concurrent": "0"]))
        XCTAssertThrowsError(try d.applying(["naming.suffix": "a/b"]))
        XCTAssertThrowsError(try d.applying(["nope": "1"]))
        XCTAssertThrowsError(try d.applying(["keepOriginal": "maybe"]))
    }

    func testSaveLoadAndOldFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ffmpeghud-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var s = FFmpegSettings()
        s.outputFolder = .custom
        s.customFolder = "/tmp/x"
        try s.save(to: url)
        XCTAssertEqual(FFmpegSettings.load(from: url), s)
        try Data(#"{"keepOriginal": false}"#.utf8).write(to: url)
        let partial = FFmpegSettings.load(from: url)
        XCTAssertFalse(partial.keepOriginal)
        XCTAssertEqual(partial.outputFolder, .same)
        XCTAssertEqual(Set(s.json.keys), ["output.folder", "output.customFolder", "naming.suffix", "keepOriginal", "jobs.concurrent"])
    }

    func testRecentsFirstThenCatalogOrder() {
        let all = PresetCatalog.all
        var recents: [String] = []
        recents = Recents.touch("gif", in: recents)
        recents = Recents.touch("trim", in: recents)
        recents = Recents.touch("gif", in: recents)
        XCTAssertEqual(recents, ["gif", "trim"])
        let ordered = Recents.ordered(all, recents: recents).map(\.id)
        XCTAssertEqual(Array(ordered.prefix(3)), ["gif", "trim", "convert"])
        XCTAssertEqual(ordered.count, all.count)
        XCTAssertEqual(Recents.ordered(all, recents: recents, query: "AUDIO").map(\.id), ["audio", "mute", "normalize"])
        XCTAssertEqual(Recents.ordered(all, recents: [], query: "gif").map(\.id), ["gif"])
        XCTAssertEqual((0..<30).reduce([String]()) { Recents.touch("p\($1)", in: $0) }.count, Recents.limit)
    }
}
