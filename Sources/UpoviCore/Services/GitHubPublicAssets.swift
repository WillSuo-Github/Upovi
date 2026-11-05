import Foundation

extension GitHubRelease {
    /// Read only GitHub's expanded-assets fragment for an already confirmed stable tag. A digest
    /// belongs to one asset row and its exact filename, never to release-body text or another row.
    static func publicAssets(_ data: Data, repository: String, tag: String) throws -> [Asset] {
        func invalid() -> PeerError { .invalid("Unconfirmed GitHub public asset proof") }
        guard validRepository(repository), !tag.isEmpty, tag.count <= 128, !tag.contains("/"),
              data.count <= 2_000_000, let html = String(data: data, encoding: .utf8),
              !html.contains("<!--"), !html.contains("<!"),
              html.range(of: #"<(?:script|template|iframe|html|head|body)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { throw invalid() }
        func matches(_ pattern: String, _ text: String) throws -> [NSTextCheckingResult] {
            try NSRegularExpression(pattern: pattern, options: .caseInsensitive).matches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        func capture(_ match: NSTextCheckingResult, _ index: Int, _ text: String) throws -> String {
            guard let range = Range(match.range(at: index), in: text) else { throw invalid() }
            return String(text[range])
        }
        // Parse every attribute, including unneeded ones, so quoted text cannot impersonate a key.
        func attributes(_ text: String) throws -> [String: String] {
            let pattern = #"\s+([a-z][a-z0-9:_-]*)(?:\s*=\s*(?:"([^"<>]*)"|'([^'<>]*)'))?"#
            var end = text.startIndex, result: [String: String] = [:]
            for match in try matches(pattern, text) {
                guard let range = Range(match.range, in: text), range.lowerBound == end else { throw invalid() }
                let key = try capture(match, 1, text).lowercased()
                let value = match.range(at: 2).location != NSNotFound ? try capture(match, 2, text)
                    : match.range(at: 3).location != NSNotFound ? try capture(match, 3, text) : ""
                guard result[key] == nil else { throw invalid() }
                result[key] = value; end = range.upperBound
            }
            guard text[end...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid() }
            return result
        }
        func unescape(_ text: String) throws -> String {
            var result = "", end = text.startIndex
            for match in try matches(#"&[^;\s]{1,12};"#, text) {
                guard let range = Range(match.range, in: text) else { throw invalid() }
                let entity = String(text[range])
                let scalar: String?
                switch entity {
                case "&amp;": scalar = "&"
                case "&quot;": scalar = "\""
                case "&#39;", "&apos;": scalar = "'"
                case "&lt;": scalar = "<"
                case "&gt;": scalar = ">"
                default: scalar = nil
                }
                guard let scalar else { throw invalid() }
                let prefix = String(text[end..<range.lowerBound]); guard !prefix.contains("&") else { throw invalid() }
                result += prefix + scalar; end = range.upperBound
            }
            guard !text[end...].contains("&") else { throw invalid() }
            return result + text[end...]
        }
        let openings = try matches(#"<li\b([^<>]*)>"#, html)
        let pieces = html.components(separatedBy: "</li>")
        guard !openings.isEmpty, openings.count <= 200, pieces.count == openings.count + 1 else { throw invalid() }
        var assets: [Asset] = [], names = Set<String>()
        for piece in pieces.dropLast() {
            guard piece.utf8.count <= 65_536 else { throw invalid() }
            let starts = try matches(#"<li\b([^<>]*)>"#, piece)
            guard starts.count == 1, let start = starts.first,
                  try attributes(capture(start, 1, piece))["class"]?.split(separator: " ").contains("Box-row") == true else { throw invalid() }
            let row = String(piece[Range(start.range, in: piece)!.upperBound...])
            let links = try matches(#"<a\b([^<>]*)>"#, row)
            guard links.count == 1, let link = links.first,
                  let rawHref = try attributes(capture(link, 1, row))["href"] else { throw invalid() }
            let href = try unescape(rawHref)
            guard let url = URL(string: href, relativeTo: URL(string: "https://github.com")!)?.absoluteURL,
                  url.scheme == "https", url.host == "github.com", url.port == nil, url.user == nil,
                  url.password == nil, url.query == nil, url.fragment == nil else { throw invalid() }
            let path = url.pathComponents
            let repoParts = repository.split(separator: "/").map(String.init)
            guard path.count >= 3, path[1].lowercased() == repoParts[0].lowercased(),
                  path[2].lowercased() == repoParts[1].lowercased() else { throw invalid() }
            if path.count == 7, path[3] == "archive", path[4] == "refs", path[5] == "tags",
               [tag + ".zip", tag + ".tar.gz"].contains(path[6]) { continue }
            guard path.count == 7, path[3] == "releases", path[4] == "download", path[5] == tag else { throw invalid() }
            let name = path[6]
            guard !name.isEmpty, name.count <= 255, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), names.insert(name).inserted else { throw invalid() }
            let copies = try matches(#"<clipboard-copy\b([^<>]*)>"#, row)
            let digest: String?
            if copies.isEmpty { digest = nil }
            else {
                guard copies.count == 1, let copy = copies.first else { throw invalid() }
                let attrs = try attributes(capture(copy, 1, row))
                guard let label = attrs["aria-label"], try unescape(label) == "Copy to clipboard digest for " + name,
                      let value = attrs["value"], value.range(of: #"^sha256:[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else { throw invalid() }
                let visible = try matches(#"<span\b([^<>]*)>\s*(sha256:[^<>\s]+)\s*</span>"#, row)
                guard visible.count == 1, let visibleProof = visible.first,
                      try attributes(capture(visibleProof, 1, row))["class"]?.split(separator: " ").contains("Truncate-text") == true,
                      try capture(visibleProof, 2, row).lowercased() == value.lowercased() else { throw invalid() }
                digest = value.lowercased()
            }
            assets.append(.init(name: name, browser_download_url: url, digest: digest))
        }
        return assets
    }
}
