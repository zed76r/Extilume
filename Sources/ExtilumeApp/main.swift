import ExtilumeNative
import Darwin
import Foundation

setlinebuf(stdout)

if CommandLine.arguments.dropFirst().first == "--display-snapshot" {
    runDisplayProbe()
} else {
    do {
        try runMenuBarApplication()
    } catch {
        FileHandle.standardError.write(Data("启动失败：无法安全启动 Extilume。\n".utf8))
        exit(EXIT_FAILURE)
    }
}
