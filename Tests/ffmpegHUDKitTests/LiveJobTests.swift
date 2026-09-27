@testable import ffmpegHUDKit
import XCTest

/// Runs real ffmpeg on clips generated with `-f lavfi` in a temp directory (never on the
/// user's files). Skipped when ffmpeg is not installed.
@MainActor
final class LiveJobTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        try XCTSkipIf(Executables.path("ffmpeg") == nil || Executables.path("ffprobe") == nil, "ffmpeg is not installed")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ffmpeghud-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A test pattern with a tone, `seconds` long.
    private func makeClip(_ name: String, seconds: Int = 2, size: String = "320x240") throws -> String {
        let path = dir.appendingPathComponent(name).path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Executables.path("ffmpeg")!)
        task.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                          "-f", "lavfi", "-i", "testsrc=size=\(size):rate=25:duration=\(seconds)",
                          "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
                          "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", path]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        return path
    }

    private func wait(_ queue: JobQueue, for id: Int, timeout: TimeInterval = 60, until: ((Job) -> Bool)? = nil) -> Job? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = queue.job(id), until.map({ $0(job) }) ?? !job.isActive { return job }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return queue.job(id)
    }

    func testProbe() throws {
        let clip = try makeClip("probe.mp4")
        let info = try Probe.run(clip).get()
        XCTAssertEqual(info.duration!, 2, accuracy: 0.1)
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(info.videoCodec, "h264")
        XCTAssertEqual(info.audioCodec, "aac")
        if case .success = Probe.run(dir.appendingPathComponent("missing.mov").path) { XCTFail("a missing file probes") }
    }

    /// Every preset, prefilled values, on a real clip: each must succeed and leave a non-empty
    /// file with the name the naming rules promise.
    func testEveryPresetRunsOnAGeneratedClip() throws {
        let clip = try makeClip("clip.mp4")
        let queue = JobQueue(settings: FFmpegSettings())
        var ids: [String: Int] = [:]
        for preset in PresetCatalog.all {
            let inputs = preset.multiInput ? [clip, clip] : [clip]
            ids[preset.id] = try queue.enqueue(preset: preset, values: PresetValues(preset: preset), inputs: inputs).id
        }
        for preset in PresetCatalog.all {
            let job = try XCTUnwrap(wait(queue, for: ids[preset.id]!))
            XCTAssertEqual(job.state, .succeeded, "\(preset.id): \(job.error ?? "")")
            let size = (try? FileManager.default.attributesOfItem(atPath: job.output)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size, 0, preset.id)
            if preset.id != PresetCatalog.thumbnail.id { XCTAssertEqual(job.fraction, 1, preset.id) }
        }
        let gif = queue.job(ids["gif"]!)!
        XCTAssertEqual(gif.output, dir.appendingPathComponent("clip_gif.gif").path)
        XCTAssertEqual(try Probe.run(gif.output).get().videoCodec, "gif")
        let concat = try Probe.run(queue.job(ids["concat"]!)!.output).get()
        XCTAssertEqual(concat.duration!, 4, accuracy: 0.2, "two 2 s clips joined")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip), "the original is kept")
    }

    func testSecondRunGetsANewName() throws {
        let clip = try makeClip("again.mp4")
        let queue = JobQueue()
        let first = try queue.enqueue(preset: PresetCatalog.mute, values: PresetValues(preset: PresetCatalog.mute), inputs: [clip])
        let second = try queue.enqueue(preset: PresetCatalog.mute, values: PresetValues(preset: PresetCatalog.mute), inputs: [clip])
        XCTAssertEqual(first.output, dir.appendingPathComponent("again_muted.mp4").path)
        XCTAssertEqual(second.output, dir.appendingPathComponent("again_muted-2.mp4").path, "reserved while queued")
        XCTAssertEqual(wait(queue, for: second.id)?.state, .succeeded)
        XCTAssertEqual(wait(queue, for: first.id)?.state, .succeeded)
        let third = try queue.enqueue(preset: PresetCatalog.mute, values: PresetValues(preset: PresetCatalog.mute), inputs: [clip])
        XCTAssertEqual(third.output, dir.appendingPathComponent("again_muted-3.mp4").path, "exists on disk")
        XCTAssertEqual(wait(queue, for: third.id)?.state, .succeeded)
        XCTAssertThrowsError(try queue.enqueue(preset: PresetCatalog.mute, values: PresetValues(preset: PresetCatalog.mute),
                                               inputs: [clip], output: third.output)) {
            XCTAssertEqual($0 as? JobError, .outputExists(third.output))
        }
    }

    func testProgressThenCancelRemovesThePartialOutput() throws {
        let clip = try makeClip("long.mp4", seconds: 60, size: "640x360")
        let queue = JobQueue()
        let preset = PresetCatalog.compress
        let values = PresetValues(preset: preset).applying(["crf": "18", "speed": "slow"], preset: preset)
        let job = try queue.enqueue(preset: preset, values: values, inputs: [clip])
        let moving = wait(queue, for: job.id, timeout: 30) { ($0.fraction ?? 0) > 0 || !$0.isActive }
        XCTAssertEqual(moving?.state, .running, moving?.error ?? "")
        XCTAssertEqual(moving?.expectedDuration ?? 0, 60, accuracy: 0.5, "probed before running")
        XCTAssertLessThan(moving?.fraction ?? 1, 1)
        XCTAssertTrue(queue.cancel(job.id))
        let done = wait(queue, for: job.id, timeout: 10)
        XCTAssertEqual(done?.state, .cancelled)
        XCTAssertNil(done?.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.output), "partial output removed")
    }

    func testShutdownStopsFFmpegAndRemovesPartialOutput() throws {
        let clip = try makeClip("quit.mp4", seconds: 60, size: "640x360")
        let queue = JobQueue()
        let preset = PresetCatalog.compress
        let values = PresetValues(preset: preset).applying(["crf": "18", "speed": "slow"], preset: preset)
        let job = try queue.enqueue(preset: preset, values: values, inputs: [clip])
        let moving = wait(queue, for: job.id, timeout: 30) { $0.written > 0 || !$0.isActive }
        XCTAssertEqual(moving?.state, .running)
        queue.shutdown()
        XCTAssertEqual(queue.job(job.id)?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.output), "no half-written file left behind")
        XCTAssertEqual(queue.activeCount, 0)
    }

    func testFailureKeepsFFmpegsWords() throws {
        let clip = try makeClip("fail.mp4")
        let queue = JobQueue()
        // An extension no muxer claims: ffmpeg refuses ("Unable to choose an output format").
        let preset = PresetCatalog.remux
        let job = try queue.enqueue(preset: preset, values: PresetValues(preset: preset), inputs: [clip],
                                    output: dir.appendingPathComponent("out.notaformat").path)
        let done = wait(queue, for: job.id)
        XCTAssertEqual(done?.state, .failed)
        XCTAssertFalse(done?.error?.isEmpty ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.output))
    }

    func testKeepOriginalOffTrashesTheInput() throws {
        let clip = try makeClip("trashme.mp4")
        var settings = FFmpegSettings()
        settings.keepOriginal = false
        var trashed: [URL] = []
        let queue = JobQueue(settings: settings, trash: { trashed.append($0) })
        let job = try queue.enqueue(preset: PresetCatalog.mute, values: PresetValues(preset: PresetCatalog.mute), inputs: [clip])
        let done = wait(queue, for: job.id)
        XCTAssertEqual(done?.state, .succeeded)
        XCTAssertEqual(trashed.map(\.path), [clip])
        XCTAssertEqual(done?.trashedOriginal, true)
    }

    func testConcurrencyLimit() throws {
        let clip = try makeClip("many.mp4")
        var settings = FFmpegSettings()
        settings.concurrentJobs = 1
        let queue = JobQueue(settings: settings)
        let ids = try (0..<3).map { _ in
            try queue.enqueue(preset: PresetCatalog.mute, values: PresetValues(preset: PresetCatalog.mute), inputs: [clip]).id
        }
        XCTAssertEqual(queue.runningCount, 1)
        XCTAssertEqual(queue.jobs.filter { $0.state == .queued }.count, 2)
        XCTAssertTrue(queue.cancel(ids[2]))
        XCTAssertEqual(queue.job(ids[2])?.state, .cancelled)
        XCTAssertEqual(wait(queue, for: ids[1])?.state, .succeeded)
        XCTAssertEqual(queue.activeCount, 0)
        queue.clearFinished()
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func testEncoderListAndMissingEncoderRefused() throws {
        let clip = try makeClip("enc.mp4")
        let queue = JobQueue()
        let deadline = Date().addingTimeInterval(10)
        while queue.encoders == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let encoders = try XCTUnwrap(queue.encoders)
        XCTAssertTrue(encoders.contains("libx264"))
        XCTAssertTrue(encoders.contains("aac"))
        let preset = PresetCatalog.convert
        for option in preset.field("format")!.options {
            let values = PresetValues(preset: preset).applying(["format": option.value], preset: preset)
            if queue.isAvailable(option) {
                XCTAssertNoThrow(try queue.plannedCommand(preset: preset, values: values, inputs: [clip]), option.value)
            } else {
                XCTAssertThrowsError(try queue.enqueue(preset: preset, values: values, inputs: [clip]), option.value) {
                    guard case .command(.missingEncoder) = $0 as? JobError else { return XCTFail("\($0)") }
                }
            }
        }
    }

    func testMissingInput() {
        let queue = JobQueue()
        XCTAssertThrowsError(try queue.enqueue(preset: PresetCatalog.gif, values: PresetValues(preset: PresetCatalog.gif),
                                               inputs: [dir.appendingPathComponent("nope.mov").path]))
    }
}
