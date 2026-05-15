import Foundation

/// Line-based TOML editing scoped to `[features].hooks` and the
/// `[features].codex_hooks` alias. Used by `CodexPluginInstaller` to keep
/// cctop's edits to the user's Codex config minimal: Codex defaults
/// `hooks` to true, so a clean config doesn't need touching. The editor
/// only steps in to:
///   (a) remove any `codex_hooks` line — Codex prints a startup warning
///       whenever it loads one;
///   (b) override an explicit `hooks = false` so install actually fires.
/// Anything else in the file is preserved verbatim. Avoids a TOML parser
/// dependency in favor of line-based edits.
enum CodexConfigToml {

    /// Patch `input` so hooks will fire after cctop's install. The minimal
    /// edits applied:
    ///   1. If `[features].codex_hooks` is present (any value), remove that
    ///      line — Codex emits the deprecation warning regardless of value.
    ///   2. If `[features].hooks = false` is present, override it to `true`
    ///      — install means "make hooks fire", silently leaving an opt-out
    ///      in place would break the integration.
    /// Otherwise the input is returned unchanged. We deliberately do NOT
    /// write `hooks = true` on a clean config — Codex defaults the flag to
    /// true, so an explicit write is just noise.
    static func patchEnableHooks(_ input: String) -> String {
        let lines = input.components(separatedBy: "\n")
        let scan = scan(lines)

        var updated = lines
        var changed = false

        // Override an explicit `hooks = false`.
        if let hooksIdx = scan.hooksInFeaturesIndex,
           !isHooksTrueLine(updated[hooksIdx]) {
            updated[hooksIdx] = "hooks = true"
            changed = true
        }

        // Drop the deprecated `codex_hooks` line if present. Safe to remove
        // after the replace above because the replace was in-place (no
        // length change), so `legacyIdx` is still valid.
        if let legacyIdx = scan.legacyHooksInFeaturesIndex {
            updated.remove(at: legacyIdx)
            changed = true
        }

        return changed ? updated.joined(separator: "\n") : input
    }

    /// True if hooks will fire. Mirrors Codex's own resolution: `hooks` wins
    /// if set, `codex_hooks` is the fallback, an absent flag defers to the
    /// Codex default (true). Returns false only on an explicit opt-out under
    /// `[features]`.
    static func isHooksEnabled(_ input: String) -> Bool {
        let lines = input.components(separatedBy: "\n")
        let scan = scan(lines)
        if let idx = scan.hooksInFeaturesIndex {
            return isHooksTrueLine(lines[idx])
        }
        if let idx = scan.legacyHooksInFeaturesIndex {
            return isLegacyTrueLine(lines[idx])
        }
        return true
    }

    /// True if `[features].codex_hooks` is set (regardless of value). Drives
    /// `PluginManager.codexNeedsUpdate` so existing installs see the "Update
    /// Available" prompt and get migrated on their next click.
    static func hasLegacyKey(_ input: String) -> Bool {
        let lines = input.components(separatedBy: "\n")
        return scan(lines).legacyHooksInFeaturesIndex != nil
    }

    // MARK: - Scanning

    private struct Scan {
        let featuresHeaderIndex: Int?
        let hooksInFeaturesIndex: Int?
        let legacyHooksInFeaturesIndex: Int?
    }

    private static func scan(_ lines: [String]) -> Scan {
        var current: String?
        var featuresHeaderIdx: Int?
        var hooksIdx: Int?
        var legacyIdx: Int?
        for (idx, line) in lines.enumerated() {
            if let table = parseTableHeader(line) {
                current = table
                if table == "features" && featuresHeaderIdx == nil {
                    featuresHeaderIdx = idx
                }
                continue
            }
            if isArrayOfTablesHeader(line) {
                // `[[name]]` opens an array-of-tables — a different scope
                // kind. Whatever it is, it's not `[features]`, so anything
                // inside it must not be attributed to features.
                current = nil
                continue
            }
            guard current == "features" else { continue }
            if hooksIdx == nil, isHooksAssignLine(line) {
                hooksIdx = idx
            } else if legacyIdx == nil, isLegacyAssignLine(line) {
                legacyIdx = idx
            }
        }
        return Scan(
            featuresHeaderIndex: featuresHeaderIdx,
            hooksInFeaturesIndex: hooksIdx,
            legacyHooksInFeaturesIndex: legacyIdx
        )
    }

    /// Table name from `[name]`. Nil for non-headers and `[[name]]` arrays.
    private static func parseTableHeader(_ line: String) -> String? {
        let trimmed = stripCommentAndTrim(line)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return nil }
        guard !trimmed.hasPrefix("[[") && !trimmed.hasSuffix("]]") else { return nil }
        return trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    }

    /// True for `[[name]]` array-of-tables headers. Callers use this only to
    /// know the prior table scope has ended; the name itself doesn't matter
    /// because cctop's keys live under the singular `[features]` table.
    private static func isArrayOfTablesHeader(_ line: String) -> Bool {
        let trimmed = stripCommentAndTrim(line)
        return trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]")
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

    private static func isHooksTrueLine(_ line: String) -> Bool {
        isExactAssignTrue(line, key: "hooks")
    }

    private static func isLegacyTrueLine(_ line: String) -> Bool {
        isExactAssignTrue(line, key: "codex_hooks")
    }

    private static func isExactAssignTrue(_ line: String, key: String) -> Bool {
        let effective = stripCommentAndTrim(line)
        let compact = effective.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return compact == "\(key)=true"
    }

    private static func isHooksAssignLine(_ line: String) -> Bool {
        isAssignLine(line, key: "hooks")
    }

    private static func isLegacyAssignLine(_ line: String) -> Bool {
        isAssignLine(line, key: "codex_hooks")
    }

    private static func isAssignLine(_ line: String, key: String) -> Bool {
        let effective = stripCommentAndTrim(line)
        guard effective.hasPrefix(key) else { return false }
        let afterKey = effective.dropFirst(key.count)
        guard let first = afterKey.first,
              first == " " || first == "\t" || first == "=" else {
            return false
        }
        return afterKey.contains("=")
    }
}
