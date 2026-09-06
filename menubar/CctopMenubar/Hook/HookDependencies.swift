import Foundation

// MARK: - Process Probing

/// Probes the live process tree: parent PID resolution, process start times,
/// liveness checks, and the controlling TTY. Injected into HookHandler so tests
/// can script process identity instead of inheriting the test runner's.
protocol ProcessProbing {
    func parentPID() -> UInt32
    func startTime(pid: UInt32) -> TimeInterval?
    func isAlive(pid: UInt32) -> Bool
    func commandName(pid: UInt32) -> String?
    func controllingTTY() -> String?
}

/// Production prober backed by getppid/sysctl/kill via the existing helpers.
struct LiveProcessProber: ProcessProbing {
    func parentPID() -> UInt32 { HookHandler.getParentPID() }
    func startTime(pid: UInt32) -> TimeInterval? { SessionData.processStartTime(pid: pid) }
    func isAlive(pid: UInt32) -> Bool { SessionData.processExists(pid: pid) }
    func commandName(pid: UInt32) -> String? { SessionData.processCommandName(pid: pid) }
    func controllingTTY() -> String? { HookHandler.findTTY() }
}

// MARK: - Session Name Resolution

/// Resolves user-visible session names from harness-specific local sources
/// (Codex's session index, Claude Desktop's session metadata, CC transcripts).
protocol SessionNameResolving {
    func codexThreadName(sessionId: String) -> String?
    func claudeDesktopTitle(cliSessionId: String) -> String?
    func transcriptSessionName(transcriptPath: String?, sessionId: String) -> String?
}

/// Production resolver delegating to SessionNameLookup. The source paths are
/// injectable so tests can stage fixture files in temporary directories.
struct LiveSessionNameResolver: SessionNameResolving {
    var codexIndexPath: String = Config.codexSessionIndexPath()
    var claudeSessionsDir: String = Config.claudeCodeSessionsDir()

    func codexThreadName(sessionId: String) -> String? {
        SessionNameLookup.lookupCodexThreadName(sessionId: sessionId, indexPath: codexIndexPath)
    }

    func claudeDesktopTitle(cliSessionId: String) -> String? {
        SessionNameLookup.lookupClaudeDesktopTitle(cliSessionId: cliSessionId, baseDir: claudeSessionsDir)
    }

    func transcriptSessionName(transcriptPath: String?, sessionId: String) -> String? {
        SessionNameLookup.lookupSessionName(transcriptPath: transcriptPath, sessionId: sessionId)
    }
}

// MARK: - Hook Dependencies

/// The full dependency seam for HookHandler: every file-IO path, environment
/// read, subprocess spawn, and process probe goes through this struct. The
/// `.live` value reproduces production behavior (including CCTOP_* env-var
/// overrides honored by the Config accessors).
struct HookDependencies {
    var sessionsDir: () -> String
    var environment: () -> [String: String]
    var currentBranch: (String) -> String
    var process: any ProcessProbing
    var names: any SessionNameResolving
    var logger: HookLogger

    /// Computed (not stored) so each hook invocation re-reads the environment,
    /// preserving the env-var override behavior of the Config accessors.
    static var live: HookDependencies {
        HookDependencies(
            sessionsDir: { Config.sessionsDir() },
            environment: { ProcessInfo.processInfo.environment },
            currentBranch: { getCurrentBranch(cwd: $0) },
            process: LiveProcessProber(),
            names: LiveSessionNameResolver(),
            logger: HookLogger()
        )
    }
}

// MARK: - Session File Locking

/// Acquire an exclusive flock on a `.lock` file alongside the session file.
/// This serializes concurrent hook processes operating on the same session,
/// preventing read-modify-write races when multiple hooks fire simultaneously.
func withSessionLock(
    sessionPath: String,
    onError: (String) -> Void = { HookLogger().logError($0) },
    body: () throws -> Void
) throws {
    _ = try withSessionLock(
        sessionPath: sessionPath, blocking: true, caller: "withSessionLock", onError: onError, body: body
    )
}

/// Try to acquire the per-session lock without waiting. Returns `false` when another
/// process currently owns the lock, so UI-side maintenance can skip this pass instead
/// of blocking the main actor behind a hook process.
@discardableResult
func withSessionLockIfAvailable(
    sessionPath: String,
    onError: (String) -> Void = { HookLogger().logError($0) },
    body: () throws -> Void
) throws -> Bool {
    try withSessionLock(
        sessionPath: sessionPath, blocking: false, caller: "withSessionLockIfAvailable", onError: onError, body: body
    )
}

/// Shared flock cycle for both entry points. `caller` keeps the diagnostic messages
/// attributed to the public function that was invoked.
private func withSessionLock(
    sessionPath: String,
    blocking: Bool,
    caller: String,
    onError: (String) -> Void,
    body: () throws -> Void
) throws -> Bool {
    let lockPath = sessionPath + ".lock"
    let fd = open(lockPath, O_CREAT | O_WRONLY, 0o600)
    guard fd >= 0 else {
        let err = errno
        onError("\(caller): open(\(lockPath)) failed: \(err)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                      userInfo: [NSLocalizedDescriptionKey: "Failed to open lock file: \(lockPath)"])
    }
    defer { close(fd) }
    guard flock(fd, blocking ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else {
        let err = errno
        if !blocking, err == EWOULDBLOCK || err == EAGAIN {
            return false
        }
        onError("\(caller): flock(\(lockPath)) failed: \(err)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                      userInfo: [NSLocalizedDescriptionKey: "Failed to acquire lock: \(lockPath)"])
    }
    defer { flock(fd, LOCK_UN) }
    try body()
    return true
}
