import AppKit

// MARK: - Strategy (testable, pure logic)

/// Describes how to focus a terminal session. Resolved by pure logic, executed by AppKit.
enum FocusStrategy: Equatable {
    /// Open a file/folder with a specific app via its bundle ID.
    case openWithApp(bundleID: String, target: String)
    /// Focus an iTerm2 session by its unique GUID, with a bundle ID fallback.
    case iTerm2(guid: String)
    /// Focus a Kitty window via remote control socket, with bundle ID fallback.
    case kitty(socket: String, windowId: String, binaryPath: String)
    /// Focus a Ghostty terminal by marking its TTY cwd, with a working-directory fallback.
    case ghostty(GhosttyFocusTarget)
    /// Focus an Apple Terminal tab by its tty (e.g. /dev/ttys003), with a bundle ID fallback.
    case appleTerminal(tty: String)
    /// Activate a running app by its localized name.
    case activateByName(String)
    /// Activate a running app by its bundle identifier.
    case activateByBundleID(String)
    /// Open an app-specific deep link URL (e.g. codex://threads/...), optionally restoring the target app first.
    case openURL(URL, restoreBundleID: String? = nil)
    /// Open a path in Finder.
    case openInFinder(String)
    /// Explain why the selected session cannot be focused safely.
    case unavailable(FocusFailure)
}

struct GhosttyFocusTarget: Equatable {
    let tty: String?
    let matchDirectory: String
    let restoreDirectory: String?
}

/// Resolve which strategy to use for jumping to a session.
/// Pure function — no AppKit side effects, fully testable.
func resolveFocusStrategy(session: Session) -> FocusStrategy {
    resolveFocusStrategy(session: session, multiplexerOverride: nil)
}

/// Resolve which strategy to use for jumping to a session, optionally using
/// freshly resolved multiplexer metadata for legacy live sessions.
/// Pure function — no AppKit side effects, fully testable.
func resolveFocusStrategy(
    session: Session,
    multiplexerOverride: MultiplexerInfo?
) -> FocusStrategy {
    let terminal = session.terminal
    let multiplexer = multiplexerOverride ?? terminal?.multiplexer

    // Direct terminal/editor metadata wins. A Codex session without it uses its exact
    // thread deep link. Persisted `com.openai.codex` metadata is ignored.
    let programHost = HostApp.from(editorName: terminal?.program)
    let directHost = multiplexer?.isCmux == true ? HostApp.cmux : programHost
    let hasDirectHostEvidence = terminal?.program.isEmpty == false || terminal?.tty?.isEmpty == false || multiplexer != nil
    let hostApp = session.trustedHostApp
        ?? (hasDirectHostEvidence ? directHost : nil)
        ?? (session.isCodex ? HostApp.codexDesktop : nil)
        ?? .unknown
    let target = session.workspaceFile ?? session.projectPath

    if hostApp == .cmux,
       let url = cmuxNavigationURL(multiplexer: multiplexer) {
        return .openURL(url)
    }

    if let url = hostApp.sessionDeepLink(sessionId: session.sessionId) {
        return .openURL(url, restoreBundleID: hostApp.bundleID)
    }
    if session.isCodex, hostApp == .codexDesktop {
        return .unavailable(.codexTaskIdentifierInvalid)
    }

    // Editors with a known bundle ID → open the project with that app.
    // Uses NSWorkspace instead of CLI (e.g., `code <path>`) to avoid PATH issues
    // when the app is relaunched by Sparkle (minimal PATH, CLI not found).
    // Tradeoff: NSWorkspace goes through LaunchServices rather than the editor's IPC,
    // so users with `window.openFoldersInNewWindow: "on"` may get a new window
    // instead of focusing the existing one. The default ("default") reuses existing windows.
    if hostApp.cliCommand != nil, let bundleID = hostApp.bundleID {
        return .openWithApp(bundleID: bundleID, target: target)
    }

    // iTerm2 → AppleScript to focus the specific session
    if hostApp == .iterm2,
       let guid = extractITermGUID(from: terminal?.sessionId),
       guid.range(of: #"^[0-9a-fA-F-]+$"#, options: .regularExpression) != nil {
        return .iTerm2(guid: guid)
    }

    // Kitty → remote control to focus the specific window (pane in Kitty's terms)
    if hostApp == .kitty,
       let socket = terminal?.socket,
       let windowId = terminal?.sessionId,
       let binaryPath = terminal?.binaryPaths?["kitty"] {
        return .kitty(socket: socket, windowId: windowId, binaryPath: binaryPath)
    }

    if hostApp == .ghostty {
        return .ghostty(ghosttyFocusTarget(for: session))
    }

    // Apple Terminal → AppleScript to focus the specific tab by tty.
    // NSRunningApplication.activate() can't target a single tab, and on macOS
    // Sonoma+ cooperative activation often fails to even raise the app.
    if hostApp == .terminal,
       let tty = terminal?.tty,
       tty.range(of: #"^/dev/ttys\d+$"#, options: .regularExpression) != nil {
        return .appleTerminal(tty: tty)
    }

    // Try activation by name, then bundle ID, then Finder
    if let name = hostApp.activationName {
        return .activateByName(name)
    }
    if let bundleID = hostApp.bundleID {
        return .activateByBundleID(bundleID)
    }
    return .openInFinder(session.projectPath)
}

// MARK: - Execution (AppKit side effects)

private let focusQueue = DispatchQueue(label: "cctop.focus-terminal", qos: .userInitiated)
/// Cmux `ps` probing, focus scripts, and kitty/multiplexer CLIs all block — so the whole jump runs on `focusQueue`, serial so a
/// slow jump can't finish after (and steal focus from) a later one. AppKit calls hop back to the main thread.
func focusTerminal(session: Session) {
    focusQueue.async {
        let multiplexerOverride = resolveCmuxLiveMultiplexer(session: session)
        let strategy = resolveFocusStrategy(session: session, multiplexerOverride: multiplexerOverride)
        let muxStrategy = resolveMultiplexerFocus(session: session, multiplexerOverride: multiplexerOverride,
                                                  primaryStrategy: strategy)
        let shouldDeactivate = executeFocusStrategy(strategy)
        if let mux = muxStrategy {
            executeMultiplexerFocus(mux)
        }
        if shouldDeactivate {
            DispatchQueue.main.async {
                NSApp.deactivate()
            }
        }
    }
}

/// Runs on a background queue: script/subprocess strategies block until done,
/// while pure-AppKit strategies dispatch to the main thread.
@discardableResult
private func executeFocusStrategy(_ strategy: FocusStrategy) -> Bool {
    switch strategy {
    case .openWithApp(let bundleID, let target):
        DispatchQueue.main.async {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open(
                    [URL(fileURLWithPath: target)],
                    withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } else {
                // App not installed — open in Finder
                NSWorkspace.shared.open(URL(fileURLWithPath: target))
            }
        }

    case .iTerm2(let guid):
        runScriptOrActivate(.iterm2) { executeITerm2Script(guid: guid) }

    case .kitty(let socket, let windowId, let binaryPath):
        runScriptOrActivate(.kitty) {
            executeKittyFocusWindow(binaryPath: binaryPath, socket: socket, windowId: windowId)
        }

    case .ghostty(let target):
        executeGhosttyFocus(target: target)

    case .appleTerminal(let tty):
        runScriptOrActivate(.terminal) { executeAppleTerminalScript(tty: tty) }

    case .activateByName(let name):
        DispatchQueue.main.async {
            // If no running app matches the name, recover the bundle ID and activate (or launch) by bundle ID.
            if !activateAppByName(name), let bundleID = HostApp.from(editorName: name).bundleID {
                activateAppByBundleID(bundleID)
            }
        }

    case .activateByBundleID(let bundleID):
        DispatchQueue.main.async {
            activateAppByBundleID(bundleID)
        }

    case .openURL(let url, let restoreBundleID):
        return executeAppURLStrategy(url: url, restoreBundleID: restoreBundleID)

    case .openInFinder(let path):
        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }

    case .unavailable(let failure):
        DispatchQueue.main.async {
            presentFocusFailure(failure)
        }
        return false
    }
    return true
}

/// Run a focus script for `host` (blocking, on the calling background queue);
/// if it fails, fall back to activating the host by bundle ID on the main thread.
private func runScriptOrActivate(_ host: HostApp, script: () -> Bool) {
    if !script(), let bundleID = host.bundleID {
        DispatchQueue.main.async {
            activateAppByBundleID(bundleID)
        }
    }
}

// MARK: - iTerm2 AppleScript

func extractITermGUID(from sessionId: String?) -> String? {
    guard let id = sessionId, !id.isEmpty else { return nil }
    guard let colonIndex = id.lastIndex(of: ":") else { return id }
    return String(id[id.index(after: colonIndex)...])
}

// Called on a background queue. Per the AppleScript 10.6 release notes, OSA,
// AppleScript, and NSAppleScript are thread-safe; each call here uses a fresh
// instance confined to one thread anyway. OSA still executes scripting-addition
// commands (e.g. `delay`) on the main thread for compatibility.
private func runAppleScript(_ source: String) -> Bool {
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    return error == nil
}

private func runAppleScriptReturningBool(_ source: String) -> Bool {
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    guard error == nil else { return false }
    return result?.booleanValue ?? false
}

private func executeITerm2Script(guid: String) -> Bool {
    runAppleScript("""
    tell application "iTerm2"
        activate
        repeat with w in windows
            tell w
                repeat with t in tabs
                    tell t
                        repeat with s in sessions
                            if (unique id of s) is equal to "\(guid)" then
                                set miniaturized of w to false
                                set index of w to 1
                                select t
                                tell s to select
                                return
                            end if
                        end repeat
                    end tell
                end repeat
            end tell
        end repeat
    end tell
    """)
}

// MARK: - Apple Terminal AppleScript
// Each Terminal tab exposes its `tty` (e.g. /dev/ttys003) over AppleScript. For
// a shell running directly in a tab the match is unambiguous. Under a multiplexer
// (tmux, screen) the captured tty is the multiplexer pane's pty and won't appear
// in Terminal's tab list — the loop no-ops, but the leading `activate` still
// raises the app (the previous .activateByName behavior, more reliable on Sonoma+).

private func executeAppleTerminalScript(tty: String) -> Bool {
    runAppleScript("""
    tell application "Terminal"
        activate
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "\(tty)" then
                    set miniaturized of w to false
                    set selected of t to true
                    set frontmost of w to true
                    return
                end if
            end repeat
        end repeat
    end tell
    """)
}

// MARK: - Ghostty AppleScript
// Ghostty 1.3.0+ exposes an AppleScript API (windows → tabs → terminals).
// Each `terminal` (= one split/pane) has `id`, `name`, `working directory`.
// No env var carries the terminal id into the shell yet, so we write a temporary
// OSC 7 cwd marker to the target TTY, match that marker over AppleScript, then
// restore the real cwd. This avoids the same-repo ambiguity of raw cwd matching.
//
// If the TTY is unavailable or closed, we fall back to raw cwd matching. That is
// still best-effort: ambiguous when multiple Ghostty splits share the same cwd
// (picks first), and breaks if the user `cd`s elsewhere after session start.
//
// We walk windows → tabs → terminals (instead of `every terminal whose …`) so
// we keep a reference to the parent window, then call `activate window` on it
// before focusing the surface. The leading `activate` only raises whichever
// Ghostty window was most recently active, so without the explicit
// `activate window w` the wrong window can stay on top when the user clicks
// a session whose window is sitting behind another Ghostty window.
//
// Tracked upstream:
//   - ghostty-org/ghostty#9084  (TERM_SESSION_ID request)
//   - ghostty-org/ghostty#10603 (GHOSTTY_SURFACE_ID env var + URL scheme)
// FUTURE: when GHOSTTY_SURFACE_ID ships, capture it in
// HookHandler.captureTerminalInfo() and switch this script to `whose id is …`
// for an exact, unambiguous match (analogous to iTerm2's GUID strategy).

/// Escape a string for safe interpolation inside an AppleScript double-quoted literal.
func escapeAppleScriptString(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Build the OSC 7 byte sequence (`ESC ] 7 ; file://HOST/PATH BEL`).
/// Path is URL-encoded so spaces / non-ASCII don't break the URI form.
func buildOSC7CWD(host: String, workingDirectory: String) -> String {
    let encoded = workingDirectory
        .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workingDirectory
    return "\u{1B}]7;file://\(host)\(encoded)\u{07}"
}

func ghosttyFocusTarget(for session: Session, temporaryDirectory: String = NSTemporaryDirectory()) -> GhosttyFocusTarget {
    guard let tty = session.terminal?.tty,
          tty.range(of: #"^/dev/ttys\d+$"#, options: .regularExpression) != nil else {
        return GhosttyFocusTarget(tty: nil, matchDirectory: session.projectPath, restoreDirectory: nil)
    }
    let sessionComponent = sanitizedGhosttyFocusComponent(session.sessionId)
    let ttyComponent = sanitizedGhosttyFocusComponent(URL(fileURLWithPath: tty).lastPathComponent)
    let markerName = "cctop-ghostty-focus-\(sessionComponent)-\(ttyComponent)"
    let marker = URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
        .appendingPathComponent(markerName, isDirectory: true)
        .path
    return GhosttyFocusTarget(tty: tty, matchDirectory: marker, restoreDirectory: session.projectPath)
}

private func sanitizedGhosttyFocusComponent(_ value: String) -> String {
    let sanitized = Session.sanitizeSessionId(raw: value)
    return sanitized.isEmpty ? "session" : sanitized
}

private func executeGhosttyFocus(target: GhosttyFocusTarget) {
    guard let tty = target.tty,
          let restoreDirectory = target.restoreDirectory else {
        runScriptOrActivate(.ghostty) {
            executeGhosttyFocusScript(workingDirectory: target.matchDirectory)
        }
        return
    }

    let markerCreated: Bool
    do {
        try FileManager.default.createDirectory(
            atPath: target.matchDirectory,
            withIntermediateDirectories: true
        )
        markerCreated = true
    } catch {
        markerCreated = false
    }

    let canUseMarker = markerCreated && primeGhosttyCWD(tty: tty, workingDirectory: target.matchDirectory)
    defer {
        if canUseMarker {
            _ = primeGhosttyCWD(tty: tty, workingDirectory: restoreDirectory)
        }
        if markerCreated {
            try? FileManager.default.removeItem(atPath: target.matchDirectory)
        }
    }

    runScriptOrActivate(.ghostty) {
        for directory in ghosttyFocusCandidateDirectories(target: target, markerPrimed: canUseMarker)
        where executeGhosttyFocusScript(workingDirectory: directory) {
            return true
        }
        return false
    }
}

func ghosttyFocusCandidateDirectories(target: GhosttyFocusTarget, markerPrimed: Bool) -> [String] {
    guard let restoreDirectory = target.restoreDirectory else {
        return [target.matchDirectory]
    }
    return markerPrimed ? [target.matchDirectory, restoreDirectory] : [restoreDirectory]
}

func buildGhosttyFocusScript(workingDirectory: String) -> String {
    let escaped = escapeAppleScriptString(workingDirectory)
    return """
    tell application "Ghostty"
        activate
        repeat 5 times
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        if working directory of term is "\(escaped)" then
                            activate window w
                            select tab t
                            focus term
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            delay 0.05
        end repeat
        return false
    end tell
    """
}

private func executeGhosttyFocusScript(workingDirectory: String) -> Bool {
    runAppleScriptReturningBool(buildGhosttyFocusScript(workingDirectory: workingDirectory))
}

/// Host for the OSC 7 reports written by `primeGhosttyCWD`. Ghostty treats a cwd
/// report as local only when the host is exactly "localhost" or matches
/// `gethostname()` (ghostty src/os/hostname.zig); anything else is silently
/// discarded. `ProcessInfo.hostName` can return an FQDN (VPN / corporate DNS) or
/// a ".local" name that fails that check, so sending it makes priming a no-op and
/// the jump lands on Ghostty's last-active window instead of the target session.
let ghosttyOSC7PrimingHost = "localhost"

/// Bytes written to the slave (`/dev/ttysNNN`) appear on the PTY master where Ghostty
/// parses them; the shell does not see them. Best-effort — silently no-ops if the TTY
/// has closed (session just ended).
private func primeGhosttyCWD(tty: String, workingDirectory: String) -> Bool {
    // Allow only PTY slaves (`/dev/ttys<digits>`) — that's the only shape
    // cctop-hook captures from `ps -o tty=`. This rejects /dev/cu.*, /dev/console,
    // and arbitrary file paths a tampered session JSON might supply.
    guard tty.range(of: #"^/dev/ttys\d+$"#, options: .regularExpression) != nil else { return false }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: tty),
          (attrs[.type] as? FileAttributeType) == .typeCharacterSpecial else { return false }
    let osc = buildOSC7CWD(host: ghosttyOSC7PrimingHost, workingDirectory: workingDirectory)
    guard let data = osc.data(using: .utf8) else { return false }
    guard let handle = FileHandle(forWritingAtPath: tty) else { return false }
    defer { try? handle.close() }
    do {
        try handle.write(contentsOf: data)
        return true
    } catch {
        return false
    }
}

// MARK: - Kitty Remote Control
// https://sw.kovidgoyal.net/kitty/remote-control/

private func executeKittyFocusWindow(binaryPath: String, socket: String, windowId: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = ["@", "--to", socket, "focus-window", "--match", "id:\(windowId)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func openInEditor(project: RecentProject) {
    executeFocusStrategy(resolveRecentProjectOpenStrategy(project: project))
}

func openRecentResumeTarget(_ target: RecentResumeTarget) {
    executeFocusStrategy(resolveRecentResumeTargetOpenStrategy(target: target))
}
