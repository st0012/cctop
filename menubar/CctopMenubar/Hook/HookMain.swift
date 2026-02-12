import Foundation

/// CLI entry point for cctop-hook.
///
/// Called by Claude Code hooks to track session state.
/// Reads hook event JSON from stdin and updates session files in ~/.cctop/sessions/.
///
/// Usage: cctop-hook <HookName>
@main
struct HookMain {
    static let version = "0.3.0"

    static func main() {
        let args = CommandLine.arguments

        if args.count >= 2 && (args[1] == "--version" || args[1] == "-V") {
            print("cctop-hook \(version)")
            exit(0)
        }

        if args.count >= 2 && (args[1] == "--help" || args[1] == "-h") {
            printHelp()
            exit(0)
        }

        if args.count < 2 {
            HookLogger.logError("missing hook name argument")
            exit(0) // Exit 0 to not block Claude Code
        }

        let hookName = args[1]

        guard let stdinBuf = readStdin(hookName: hookName) else { exit(0) }

        let input: HookInput
        do {
            input = try JSONDecoder().decode(HookInput.self, from: Data(stdinBuf.utf8))
        } catch {
            HookLogger.logError("\(hookName): failed to parse JSON: \(error)")
            exit(0)
        }

        do {
            try HookHandler.handleHook(hookName: hookName, input: input)
        } catch {
            HookLogger.logError("\(hookName): \(error)")
            exit(0)
        }
    }

    /// Read all of stdin with a 5-second timeout. Returns nil on failure (already logged).
    private static func readStdin(hookName: String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var readResult: (String, Error?) = ("", nil)

        DispatchQueue.global().async {
            do {
                let data = try FileHandle.standardInput.readToEnd() ?? Data()
                readResult = (String(data: data, encoding: .utf8) ?? "", nil)
            } catch {
                readResult = ("", error)
            }
            semaphore.signal()
        }

        switch semaphore.wait(timeout: .now() + 5) {
        case .success:
            if let error = readResult.1 {
                HookLogger.logError("\(hookName): failed to read stdin: \(error)")
                return nil
            }
            return readResult.0
        case .timedOut:
            HookLogger.logError("\(hookName): stdin read timed out after 5s")
            return nil
        }
    }

    private static func printHelp() {
        print("cctop-hook \(version)")
        print("Claude Code hook handler for cctop session tracking.\n")
        print("This binary is called by Claude Code hooks via the cctop plugin.")
        print("It reads hook event JSON from stdin and updates session files")
        print("in ~/.cctop/sessions/.\n")
        print("USAGE:")
        print("    cctop-hook <HOOK_NAME>\n")
        print("HOOK NAMES:")
        print("    SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,")
        print("    Stop, Notification, PermissionRequest, PreCompact, SessionEnd\n")
        print("OPTIONS:")
        print("    -h, --help       Print this help message")
        print("    -V, --version    Print version")
    }
}
