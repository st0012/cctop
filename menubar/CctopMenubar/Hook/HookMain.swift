import Foundation

/// CLI entry point for cctop-hook.
///
/// Called by Claude Code hooks to track session state.
/// Reads hook event JSON from stdin and updates session files in ~/.cctop/sessions/.
///
/// Usage: cctop-hook <HookName>
@main
struct HookMain {
    static let version = "0.6.0"

    static func main() {
        let args = CommandLine.arguments

        guard args.count >= 2 else {
            HookLogger.logError("missing hook name argument")
            exit(0)
        }

        switch args[1] {
        case "--version", "-V":
            print("cctop-hook \(version)")
            exit(0)
        case "--help", "-h":
            printHelp()
            exit(0)
        default:
            break
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

    private static func readStdin(hookName: String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .success("")

        DispatchQueue.global().async {
            do {
                let data = try FileHandle.standardInput.readToEnd() ?? Data()
                result = .success(String(data: data, encoding: .utf8) ?? "")
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            HookLogger.logError("\(hookName): stdin read timed out after 5s")
            return nil
        }

        switch result {
        case .success(let text):
            return text
        case .failure(let error):
            HookLogger.logError("\(hookName): failed to read stdin: \(error)")
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
