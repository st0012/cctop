import Foundation

/// Looks up a session's custom name from Claude Code's local data.
enum SessionNameLookup {
    /// Look up the session name from Claude Code's transcript JSONL or sessions-index.json.
    /// The transcript contains `{"type":"custom-title","customTitle":"..."}` entries in real-time.
    /// Falls back to sessions-index.json for older sessions.
    static func lookupSessionName(transcriptPath: String?, sessionId: String) -> String? {
        guard let transcriptPath, !transcriptPath.isEmpty else { return nil }

        let expanded = NSString(string: transcriptPath).expandingTildeInPath

        // Primary: scan transcript JSONL for the latest custom-title entry
        if let name = lookupNameFromTranscript(path: expanded) {
            return name
        }

        // Fallback: check sessions-index.json
        let dir = (expanded as NSString).deletingLastPathComponent
        let indexPath = (dir as NSString).appendingPathComponent("sessions-index.json")
        return lookupNameFromIndex(indexPath: indexPath, sessionId: sessionId)
    }

    /// Scan the transcript JSONL for the last `custom-title` entry.
    private static func lookupNameFromTranscript(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8)
        else { return nil }

        for line in content.components(separatedBy: "\n").reversed() {
            guard line.contains("\"custom-title\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String, type == "custom-title",
                  let title = json["customTitle"] as? String, !title.isEmpty
            else { continue }
            return title
        }
        return nil
    }

    private static func lookupNameFromIndex(indexPath: String, sessionId: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]]
        else { return nil }

        guard let match = entries.last(where: { $0["sessionId"] as? String == sessionId }),
              let title = match["customTitle"] as? String, !title.isEmpty
        else { return nil }
        return title
    }
}
