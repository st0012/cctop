import Foundation

/// Line-based TOML editing scoped to `[features].codex_hooks`. Used by
/// `CodexPluginInstaller` to enable Codex's experimental hooks system without
/// pulling in a full TOML parser dependency. Only knows about table headers,
/// inline comments, and the single key it cares about — anything else in the
/// file is preserved verbatim.
enum CodexConfigToml {

    /// Patch `input` so that `[features].codex_hooks = true` is set. The four
    /// rules are scoped to `[features]`; a `codex_hooks` key in any other
    /// table is a different key and is left alone.
    ///   1. Already `= true` → no change.
    ///   2. Present with another value → replace that line.
    ///   3. `[features]` exists with no scoped key → insert after header.
    ///   4. No `[features]` → append fresh section.
    static func patchEnableCodexHooks(_ input: String) -> String {
        let lines = input.components(separatedBy: "\n")
        let scan = scan(lines)

        if let idx = scan.codexHooksInFeaturesIndex,
           isCodexHooksTrueLine(lines[idx]) {
            return input
        }
        if let idx = scan.codexHooksInFeaturesIndex {
            var updated = lines
            updated[idx] = "codex_hooks = true"
            return updated.joined(separator: "\n")
        }
        if let idx = scan.featuresHeaderIndex {
            var updated = lines
            updated.insert("codex_hooks = true", at: idx + 1)
            return updated.joined(separator: "\n")
        }
        var result = input
        if !result.hasSuffix("\n") { result.append("\n") }
        result.append("\n[features]\ncodex_hooks = true\n")
        return result
    }

    /// True if `[features].codex_hooks = true` is set.
    static func isCodexHooksEnabled(_ input: String) -> Bool {
        let lines = input.components(separatedBy: "\n")
        let scan = scan(lines)
        guard let idx = scan.codexHooksInFeaturesIndex else { return false }
        return isCodexHooksTrueLine(lines[idx])
    }

    // MARK: - Scanning

    private struct Scan {
        let featuresHeaderIndex: Int?
        let codexHooksInFeaturesIndex: Int?
    }

    private static func scan(_ lines: [String]) -> Scan {
        var current: String?
        var featuresHeaderIdx: Int?
        var codexInFeaturesIdx: Int?
        for (idx, line) in lines.enumerated() {
            if let table = parseTableHeader(line) {
                current = table
                if table == "features" && featuresHeaderIdx == nil {
                    featuresHeaderIdx = idx
                }
                continue
            }
            if isCodexHooksAssignLine(line),
               current == "features",
               codexInFeaturesIdx == nil {
                codexInFeaturesIdx = idx
            }
        }
        return Scan(
            featuresHeaderIndex: featuresHeaderIdx,
            codexHooksInFeaturesIndex: codexInFeaturesIdx
        )
    }

    /// Table name from `[name]`. Nil for non-headers and `[[name]]` arrays.
    private static func parseTableHeader(_ line: String) -> String? {
        let trimmed = stripCommentAndTrim(line)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return nil }
        guard !trimmed.hasPrefix("[[") && !trimmed.hasSuffix("]]") else { return nil }
        return trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    }

    /// Strip any TOML inline comment and trim. Comments inside string literals
    /// are not handled — none of the values we care about are strings.
    private static func stripCommentAndTrim(_ line: String) -> String {
        let withoutComment: String
        if let hashIdx = line.firstIndex(of: "#") {
            withoutComment = String(line[..<hashIdx])
        } else {
            withoutComment = line
        }
        return withoutComment.trimmingCharacters(in: .whitespaces)
    }

    private static func isCodexHooksTrueLine(_ line: String) -> Bool {
        let effective = stripCommentAndTrim(line)
        let compact = effective.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return compact == "codex_hooks=true"
    }

    private static func isCodexHooksAssignLine(_ line: String) -> Bool {
        let effective = stripCommentAndTrim(line)
        guard effective.hasPrefix("codex_hooks") else { return false }
        let afterKey = effective.dropFirst("codex_hooks".count)
        guard let first = afterKey.first,
              first == " " || first == "\t" || first == "=" else {
            return false
        }
        return afterKey.contains("=")
    }
}
