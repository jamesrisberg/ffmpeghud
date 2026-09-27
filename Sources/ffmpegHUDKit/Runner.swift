import Foundation

/// Runs one argv (never a shell), streaming stderr line by line; ffmpeg's `\r` status
/// updates count as lines. Callbacks arrive on the main queue.
public final class FFmpegProcess: @unchecked Sendable {
    public let argv: [String]
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var pending = ""

    public init(argv: [String]) { self.argv = argv }

    public var isRunning: Bool { process.isRunning }
    public var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Splits a chunk of stderr on `\n` and `\r`, keeping an unterminated tail in `pending`.
    static func split(_ pending: inout String, _ chunk: String) -> [String] {
        pending += chunk
        let normalized = pending.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var parts = normalized.components(separatedBy: "\n")
        pending = parts.removeLast()
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `done(status, cancelled)`.
    public func start(onLine: @escaping (String) -> Void, done: @escaping (Int32, Bool) -> Void) throws {
        guard let first = argv.first else { throw Probe.ProbeError.failed("empty command") }
        guard let executable = Executables.path(first) else {
            throw Probe.ProbeError.failed("\(first) not found (brew install ffmpeg)")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            let lines = Self.split(&self.pending, String(decoding: data, as: UTF8.self))
            self.lock.unlock()
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { lines.forEach(onLine) }
        }
        process.terminationHandler = { [weak self] task in
            pipe.fileHandleForReading.readabilityHandler = nil
            // Whatever the handler had not read yet.
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            var lines: [String] = []
            var cancelled = false
            if let self {
                self.lock.lock()
                lines = Self.split(&self.pending, String(decoding: rest, as: UTF8.self) + "\n")
                cancelled = self.cancelled
                self.lock.unlock()
            }
            let status = task.terminationStatus
            DispatchQueue.main.async {
                lines.forEach(onLine)
                done(status, cancelled)
            }
        }
        try process.run()
    }

    /// For quitting: interrupts ffmpeg, waits up to `timeout` for it to go, then terminates it
    /// and waits for that. Blocks the caller.
    public func stopAndWait(timeout: TimeInterval = 1.5) {
        lock.lock()
        cancelled = true
        lock.unlock()
        guard process.isRunning else { return }
        process.interrupt()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    /// Interrupts ffmpeg (it stops cleanly on SIGINT) and terminates it if it has not gone
    /// away two seconds later.
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { process.terminate() }
        }
    }
}
