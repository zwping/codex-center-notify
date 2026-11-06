import Darwin
import Foundation

private let pluginHelperMarker = "antigravity ide helper (plugin).app/"

private struct CompletionEvent {
    static func isComplete(_ argument: String?) -> Bool {
        guard let argument, let data = argument.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["type"] as? String == "agent-turn-complete"
    }
}

private func processPath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

private func parentPID(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard size == MemoryLayout<proc_bsdinfo>.size, info.pbi_ppid > 0 else { return nil }
    return pid_t(info.pbi_ppid)
}

private func isAntigravityExtensionInvocation() -> Bool {
    var pid = getpid()
    for _ in 0..<20 {
        guard let parent = parentPID(pid), parent != pid else { break }
        if let path = processPath(parent), path.lowercased().contains(pluginHelperMarker) { return true }
        pid = parent
    }
    return false
}

private func forwardExistingCallback(_ arguments: [String]) {
    guard let marker = arguments.firstIndex(of: "--forward"), marker + 1 < arguments.count else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[marker + 1])
    process.arguments = Array(arguments.dropFirst(marker + 2))
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fputs("Could not run the existing Codex notify callback: \(error.localizedDescription)\n", stderr)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
forwardExistingCallback(arguments)

guard isAntigravityExtensionInvocation(),
      let appIndex = arguments.firstIndex(of: "--app"), appIndex + 1 < arguments.count,
      CompletionEvent.isComplete(arguments.last) else { exit(EXIT_SUCCESS) }

let appPath = arguments[appIndex + 1]
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
process.arguments = ["-n", "-a", appPath, "--args", "--display-event", arguments[arguments.count - 1]]
do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    fputs("Could not launch the Codex completion panel: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
