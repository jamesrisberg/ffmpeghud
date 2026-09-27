import ffmpegHUDKit
import Foundation
import HUDKit

// `ffmpeghud <command> [key=value ...]`: talks to ffmpegHUD's MacHUD control socket.
//
//   ffmpeghud drop ~/Movies/clip.mov
//   ffmpeghud run gif ~/Movies/clip.mov fps=10 width=320 wait=1
//   ffmpeghud run preset=trim input=clip.mov start=5 duration=10
//   ffmpeghud jobs
//   ffmpeghud cancel id=3
//   ffmpeghud watch

let usage = """
usage: ffmpeghud <command> [key=value ...]
  drop <file>...                    hand files to the panel, as if dropped on it (show=0 to leave it hidden)
  run <preset> <file>... [field=value ...] [output=] [show=1] [wait=1]
  run preset= input= [field=value ...]
                                    start a job; wait=1 blocks until it finishes (exit 1 unless it succeeded)
  jobs [id=]                        the job list, newest first, with progress
  cancel id= | cancel all=1         stop a job; its partial output is removed
  presets                           presets (recent first) and their fields
  hello | state | help | quit
  panel show|hide|toggle id=tools   panel mode id=tools full|compact|parked
  settings get [key=]  |  settings set key=value ...
  action <verb> [k=v ...]           the long form
  watch [events=state]              stream events (Ctrl-C to stop)

Relative paths are resolved against the current directory.
Environment: FFMPEGHUD_SOCKET picks the socket name (default ffmpeghud).

"""

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "ctl" { arguments.removeFirst() }
guard let command = arguments.first, !["-h", "--help"].contains(command) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty ? 2 : 0)
}

let socketName = ProcessInfo.processInfo.environment["FFMPEGHUD_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? "ffmpeghud"
let path = HUDSocket.path(for: socketName)

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("ffmpeghud: \(message)\n".utf8))
    exit(status)
}

func absolute(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
}

func request(_ args: [String: Any]) -> [String: Any] {
    do {
        return try HUDSocketClient(path: path, timeout: 0).request("action", args: args)
    } catch {
        fail("ffmpegHUD is not running (\(error))")
    }
}

func printJSON(_ object: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
}

let rest = Array(arguments.dropFirst())
let pairs = rest.filter { $0.contains("=") }
let bare = rest.filter { !$0.contains("=") }

switch command {
case "drop":
    guard !bare.isEmpty else { fail("drop needs one or more files", status: 2) }
    arguments = ["action", "name=drop", "paths=" + HUDDrop.encode(bare.map { URL(fileURLWithPath: absolute($0)) })] + pairs

case "run":
    var args = HUDSocketClient.parseArguments(pairs)
    var files = bare
    if args["preset"] == nil {
        guard !files.isEmpty else { fail("run needs a preset, e.g. `ffmpeghud run gif clip.mov`", status: 2) }
        args["preset"] = files.removeFirst()
    }
    if let input = args["input"] { args["input"] = absolute(input) }
    if let output = args["output"] { args["output"] = absolute(output) }
    if !files.isEmpty { args["inputs"] = HUDDrop.encode(files.map { URL(fileURLWithPath: absolute($0)) }) }
    let wait = ["1", "true", "yes"].contains(args.removeValue(forKey: "wait") ?? "")
    args["name"] = "run"
    let response = request(args)
    guard response["ok"] as? Bool == true, let job = response["job"] as? [String: Any], let id = job["id"] as? Int else {
        fail(response["error"] as? String ?? "run failed")
    }
    guard wait else { printJSON(response); exit(0) }
    // Poll until the job leaves queued/running, showing progress on stderr when it is a terminal.
    let tty = isatty(FileHandle.standardError.fileDescriptor) != 0
    while true {
        let status = request(["name": "jobs", "id": String(id)])
        guard let current = (status["jobs"] as? [[String: Any]])?.first, let state = current["state"] as? String else {
            fail("job \(id) disappeared")
        }
        if state != "queued" && state != "running" {
            if tty { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
            printJSON(["ok": state == "succeeded", "job": current])
            exit(state == "succeeded" ? 0 : 1)
        }
        if tty {
            let progress = (current["progress"] as? Double).map { "\(Int($0 * 100))%" } ?? state
            FileHandle.standardError.write(Data("\r\u{1B}[K\(current["title"] ?? "job") \(progress)".utf8))
        }
        usleep(400_000)
    }

case "jobs", "cancel", "presets":
    arguments = ["action", "name=\(command)"] + rest

case "settings" where rest.first.map { ["get", "set"].contains($0) } ?? false:
    // Send the sub-verb as `action=` (the router strips it; a bare `_` would read as a setting).
    arguments[1] = "action=\(arguments[1])"

case "action" where rest.first.map { !$0.contains("=") } ?? false:
    arguments[1] = "name=\(arguments[1])"

case "watch":
    let args = HUDSocketClient.parseArguments(rest)
    do {
        _ = try HUDSocketClient(path: path).subscribe(
            events: args["events"].map { $0.split(separator: ",").map(String.init) },
            onEvent: { event in
                if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                    fflush(stdout)
                }
            },
            onClose: { exit(0) }
        )
    } catch {
        fail("ffmpegHUD is not running (\(error))")
    }
    dispatchMain()

default:
    break
}

exit(HUDSocketClient.runCLI(path: path, arguments: arguments, appName: "ffmpegHUD"))
