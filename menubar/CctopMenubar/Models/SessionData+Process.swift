import Foundation

// MARK: - Process Liveness

extension SessionData {
    static func processInfo(pid: UInt32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info
    }

    static func processStartTime(pid: UInt32) -> TimeInterval? {
        guard let info = processInfo(pid: pid) else { return nil }
        return startTime(from: info)
    }

    /// True when the kernel knows the PID: `kill(pid, 0)` succeeds, or fails only because
    /// the process belongs to another user (EPERM).
    static func processExists(pid: UInt32) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }

    var isAlive: Bool {
        guard let pid, Self.processExists(pid: pid) else { return false }
        guard let info = Self.processInfo(pid: pid) else { return false }

        if let stored = pidStartTime {
            let current = Self.startTime(from: info)
            if abs(stored - current) > 1.0 { return false }
        }

        // A live process that is identifiably a DIFFERENT harness's binary cannot be this
        // session's host: the capture-time parent walk can adopt a foreign harness PID, and
        // rapid PID reuse can land within the 1s start-time tolerance (issue #155).
        if Self.isForeignHarnessComm(Self.commandName(from: info), source: source) { return false }

        // Suspended (Ctrl+Z) or orphaned (PPID=1) processes are unreachable
        if info.kp_proc.p_stat == 4 { return false }
        if info.kp_eproc.e_ppid == 1 { return false }

        return true
    }

    private static func startTime(from info: kinfo_proc) -> TimeInterval {
        let tv = info.kp_proc.p_starttime
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
    }

    /// Kernel-reported executable basename (`p_comm`, truncated to MAXCOMLEN).
    /// p_comm stores MAXCOMLEN chars + NUL; the +1 keeps a full-length comm's
    /// terminator inside the rebound region.
    static func commandName(from info: kinfo_proc) -> String {
        var proc = info.kp_proc
        return withUnsafePointer(to: &proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cStr in
                String(cString: cStr)
            }
        }
    }

    static func processCommandName(pid: UInt32) -> String? {
        processInfo(pid: pid).map { commandName(from: $0) }
    }

    /// Maps a process name to the harness that owns that binary. Codex also ships
    /// arch-suffixed binaries (`codex-aarch64-apple-darwin`, truncated by MAXCOMLEN),
    /// hence the prefix match.
    static func harnessOwningComm(_ comm: String) -> String? {
        if comm == "claude" { return ccSource }
        if comm == "codex" || comm.hasPrefix("codex-") { return codexSource }
        if comm == "opencode" { return opencodeSource }
        if comm == "pi" { return piSource }
        return nil
    }

    /// True when the process name belongs to a DIFFERENT harness than this session's.
    /// Conservative: an unrecognized name proves nothing (claude could run under a
    /// wrapper). Legacy nil sources are Claude Code sessions.
    static func isForeignHarnessComm(_ comm: String, source: String?) -> Bool {
        guard let owner = harnessOwningComm(comm) else { return false }
        return owner != (source ?? ccSource)
    }
}
