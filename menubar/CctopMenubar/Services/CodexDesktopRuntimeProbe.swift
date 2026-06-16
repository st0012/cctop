import AppKit
import Darwin
import Foundation

enum ProcessChildPIDProbe {
    static func capacity(fromReportedCount reportedCount: Int32) -> Int {
        max(0, Int(reportedCount))
    }

    static func bufferSize(forCapacity capacity: Int) -> Int32 {
        Int32(clamping: capacity * MemoryLayout<pid_t>.size)
    }

    static func returnedCount(_ reportedCount: Int32, capacity: Int) -> Int {
        min(Self.capacity(fromReportedCount: reportedCount), capacity)
    }
}

struct CodexDesktopRuntimeProbe {
    struct RunningApp: Equatable {
        let pid: pid_t
        let bundleIdentifier: String?
        let bundleURLPath: String?
    }

    struct ProcessSnapshot: Equatable {
        let pid: pid_t
        let executablePath: String
        let arguments: [String]
    }

    var runningApps: () -> [RunningApp]
    var childProcesses: (pid_t) -> [ProcessSnapshot]
    var environment: (pid_t) -> [String: String]

    init(
        runningApps: @escaping () -> [RunningApp] = Self.liveRunningCodexApps,
        childProcesses: @escaping (pid_t) -> [ProcessSnapshot] = Self.liveChildProcesses(parentPID:),
        environment: @escaping (pid_t) -> [String: String] = Self.liveAllowlistedEnvironment(pid:)
    ) {
        self.runningApps = runningApps
        self.childProcesses = childProcesses
        self.environment = environment
    }

    func currentDesktopSQLiteHome() -> String? {
        let apps = runningApps().filter { $0.bundleIdentifier == HostAppBundleID.codexDesktop }
        guard apps.count == 1, let app = apps.first else { return nil }

        let servers = childProcesses(app.pid).filter { Self.isDesktopAppServer($0, in: app) }
        guard servers.count == 1, let server = servers.first else { return nil }

        return environment(server.pid)["CODEX_SQLITE_HOME"].flatMap(Config.nonEmpty)
    }

    private static func isDesktopAppServer(_ process: ProcessSnapshot, in app: RunningApp) -> Bool {
        // The CLI and Desktop can both spawn `app-server`. The Desktop-owned
        // child is bundled under the running app, uses Desktop analytics
        // defaults, and is not a stdio/listen server.
        process.arguments.contains("app-server")
            && process.arguments.contains("--analytics-default-enabled")
            && !process.arguments.contains("--listen")
            && !process.arguments.contains("stdio://")
            && executablePath(process.executablePath, isInsideBundleAt: app.bundleURLPath)
    }

    private static func executablePath(_ executablePath: String, isInsideBundleAt bundlePath: String?) -> Bool {
        guard let bundlePath = bundlePath.flatMap(Config.nonEmpty) else { return false }
        let executable = NSString(string: executablePath).standardizingPath
        var bundle = NSString(string: bundlePath).standardizingPath
        while bundle.hasSuffix("/") {
            bundle.removeLast()
        }
        return executable == bundle || executable.hasPrefix(bundle + "/")
    }
}

extension CodexDesktopRuntimeProbe {
    static func liveRunningCodexApps() -> [RunningApp] {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: HostAppBundleID.codexDesktop)
            .map {
                RunningApp(
                    pid: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier,
                    bundleURLPath: $0.bundleURL?.path
                )
            }
    }

    static func liveChildProcesses(parentPID: pid_t) -> [ProcessSnapshot] {
        let reportedCount = proc_listchildpids(parentPID, nil, 0)
        let count = ProcessChildPIDProbe.capacity(fromReportedCount: reportedCount)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: count)
        let actual = proc_listchildpids(parentPID, &pids, ProcessChildPIDProbe.bufferSize(forCapacity: count))
        let actualCount = ProcessChildPIDProbe.returnedCount(actual, capacity: count)
        return pids.prefix(actualCount).compactMap { pid in
            guard pid > 0,
                  let details = processDetails(pid: pid) else {
                return nil
            }
            return ProcessSnapshot(
                pid: pid,
                executablePath: details.executablePath,
                arguments: details.arguments
            )
        }
    }

    static func liveAllowlistedEnvironment(pid: pid_t) -> [String: String] {
        let raw = processDetails(pid: pid)?.environment ?? [:]
        let allowlist = ["CODEX_SQLITE_HOME"]
        return Dictionary(uniqueKeysWithValues: allowlist.compactMap { key in
            raw[key].map { (key, $0) }
        })
    }

    private static func processDetails(pid: pid_t) -> (executablePath: String, arguments: [String], environment: [String: String])? {
        guard let bytes = processArgumentBytes(pid: pid), bytes.count > MemoryLayout<Int32>.size else {
            return nil
        }

        let argc = bytes.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: Int32.self)
        }
        var offset = MemoryLayout<Int32>.size
        let executablePath = readCString(from: bytes, offset: &offset) ?? ""
        skipNulls(in: bytes, offset: &offset)

        var arguments: [String] = []
        for _ in 0..<max(0, Int(argc)) {
            guard let argument = readCString(from: bytes, offset: &offset) else { break }
            if !argument.isEmpty {
                arguments.append(argument)
            }
        }

        skipNulls(in: bytes, offset: &offset)
        var environment: [String: String] = [:]
        while let entry = readCString(from: bytes, offset: &offset), !entry.isEmpty {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                environment[String(parts[0])] = String(parts[1])
            }
        }

        return (executablePath, arguments, environment)
    }

    private static func processArgumentBytes(pid: pid_t) -> [UInt8]? {
        // This reads macOS's kernel-exposed argv/env block for the process,
        // not arbitrary process memory. Callers still allowlist env keys.
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax = 0
        var argmaxSize = MemoryLayout<Int>.stride
        guard sysctl(&argmaxMib, u_int(argmaxMib.count), &argmax, &argmaxSize, nil, 0) == 0,
              argmax > 0 else {
            return nil
        }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [CChar](repeating: 0, count: argmax)
        var size = buffer.count
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return buffer.prefix(size).map { UInt8(bitPattern: $0) }
    }

    private static func readCString(from bytes: [UInt8], offset: inout Int) -> String? {
        guard offset < bytes.count else { return nil }
        let start = offset
        while offset < bytes.count && bytes[offset] != 0 {
            offset += 1
        }
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return String(bytes: bytes[start..<offset], encoding: .utf8)
    }

    private static func skipNulls(in bytes: [UInt8], offset: inout Int) {
        while offset < bytes.count && bytes[offset] == 0 {
            offset += 1
        }
    }
}
