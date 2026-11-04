import Foundation

/// Sink-level redaction, applied again to retained files during export. Never log raw payloads.
enum UpoviLogPrivacy {
    // Apply at the sink, including third-party messages and NSError descriptions.
    // Call-site helpers alone cannot protect a newly added diagnostic.
    static func sanitize(_ message: String, preservesLineBreaks: Bool = false) -> String {
        var result = message
        result = replacing(#"(?i)\b(?:https?|smb|sftp|ftp|ftps|nfs|rtsp|rtmp|file)://[^\s<>\"\)\]]+"#, in: result) { value in
            guard let url = URL(string: value), let scheme = url.scheme else { return "<url>" }
            if url.isFileURL { return "<local-file>" }
            // Paths can contain credentials too (IPTV, signed routes, NAS names).
            let host = url.host ?? "<host>"
            let port = url.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)/<path>"
        }
        result = replacing(#"(?im)\b(?:set-cookie|cookie)["']?\s*[:=]\s*[^\r\n]+"#, in: result) { _ in
            "<cookie-redacted>"
        }
        result = replacing(#"(?i)(?:authorization[\"']?\s*[:=]\s*[\"']?\s*)?(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#, in: result) { _ in
            "<authorization-redacted>"
        }
        result = replacing(#"(?i)\b(?:password|passwd|pwd|access[_-]?token|refresh[_-]?token|token|api[_-]?key|client[_-]?secret|cookie|set-cookie|secret|credential|signature)[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;\}\]]+)"#, in: result) { _ in
            "<credential-redacted>"
        }
        result = replacing(#"/(?:Users|home|private|var|Volumes|tmp|storage|data|Applications|Library|System|opt|usr|etc|bin|sbin|dev)/[^\n\r\"<>]*"#, in: result) { _ in
            "<local-path>"
        }
        // Keep each record on one line; a remote error must not forge a log header.
        if preservesLineBreaks { return result }
        return result.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static let regexes: [String: NSRegularExpression] = {
        let patterns = [
            #"(?i)\b(?:https?|smb|sftp|ftp|ftps|nfs|rtsp|rtmp|file)://[^\s<>\"\)\]]+"#,
            #"(?im)\b(?:set-cookie|cookie)["']?\s*[:=]\s*[^\r\n]+"#,
            #"(?i)(?:authorization[\"']?\s*[:=]\s*[\"']?\s*)?(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)\b(?:password|passwd|pwd|access[_-]?token|refresh[_-]?token|token|api[_-]?key|client[_-]?secret|cookie|set-cookie|secret|credential|signature)[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;\}\]]+)"#,
            #"/(?:Users|home|private|var|Volumes|tmp|storage|data|Applications|Library|System|opt|usr|etc|bin|sbin|dev)/[^\n\r\"<>]*"#,
        ]
        return Dictionary(uniqueKeysWithValues: patterns.compactMap { pattern in
            (try? NSRegularExpression(pattern: pattern)).map { (pattern, $0) }
        })
    }()

    private static func replacing(
        _ pattern: String,
        in text: String,
        transform: (String) -> String
    ) -> String {
        guard let regex = regexes[pattern] else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }

}
