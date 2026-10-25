import ExtilumeNative
import Darwin
import Foundation

setlinebuf(stdout)

if runInternalApplicationWorkerIfRequested() {
    // The private session owner runs independently of the menu process.
} else if ["--display-snapshot", "--active-display-snapshot", "--internal-display-snapshot", "--display-guard"]
    .contains(CommandLine.arguments.dropFirst().first ?? "") {
    runDisplayProbe()
} else {
    do {
        try runMenuBarApplication()
    } catch {
        FileHandle.standardError.write(Data("启动失败：无法安全启动 Extilume。\n".utf8))
        exit(EXIT_FAILURE)
    }
}
