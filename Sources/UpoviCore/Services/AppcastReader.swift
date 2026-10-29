import Foundation

public final class AppcastReader: NSObject, XMLParserDelegate {
    private var entries: [UpdateCandidate] = []
    private var current: (version: String, build: String, minimum: String, link: String, download: String, signature: String, notes: String)?
    private var element = ""
    private var text = ""
    private var channel = ""

    public static func read(_ data: Data) throws -> [UpdateCandidate] {
        let reader = AppcastReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { throw parser.parserError ?? URLError(.cannotParseResponse) }
        return reader.entries
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name; text = ""
        if name == "item" { current = ("", "", "", "", "", "", ""); channel = "" }
        if name == "enclosure", current != nil {
            guard attributes["sparkle:deltaFrom"] == nil, attributes["os"] == nil || attributes["os"] == "macos" else { return }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            if let requested = attributes["sparkle:cpuArchitecture"], requested != architecture && requested != "universal" { return }
            // Versions may also be item elements placed before the enclosure; absent attributes must not erase them.
            if let build = attributes["sparkle:version"] { current?.build = build }
            if let version = attributes["sparkle:shortVersionString"] { current?.version = version }
            current?.download = attributes["url"] ?? ""
            current?.signature = attributes["sparkle:edSignature"] ?? ""
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "sparkle:version": current?.build = value
        case "sparkle:shortVersionString": current?.version = value
        case "sparkle:minimumSystemVersion": current?.minimum = value
        case "sparkle:channel": channel = value
        case "link": current?.link = value
        case "description": current?.notes = String(value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression).prefix(20_000))
        case "item":
            if let item = current, channel.isEmpty || channel == "stable" {
                let os = ProcessInfo.processInfo.operatingSystemVersion
                let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                let minimumOrder = VersionOrder.compare(item.minimum, osString)
                let compatible = item.minimum.isEmpty || minimumOrder == .orderedAscending || minimumOrder == .orderedSame
                let version = item.version.isEmpty ? item.build : item.version
                if compatible, !version.isEmpty {
                    // A link is a user-reviewed update entry point; no peer or appcast payload is executed.
                    let url = URL(string: item.link).flatMap { $0.scheme == "https" ? $0 : nil }
                    entries.append(.init(version: version, build: item.build, source: "Developer appcast", isCommunity: false, url: url,
                                         usesBuildVersion: item.version.isEmpty,
                                         download: URL(string: item.download).flatMap { url in
                                             guard url.scheme == "https", ["zip", "dmg", "pkg"].contains(url.pathExtension.lowercased()),
                                                   let signature = Data(base64Encoded: item.signature), signature.count == 64 else { return nil }
                                             return DownloadDescriptor(url: url, edSignature: signature)
                                         }, releaseNotes: item.notes.isEmpty ? nil : item.notes))
                }
            }
            current = nil
        default: break
        }
        text = ""
    }
}
