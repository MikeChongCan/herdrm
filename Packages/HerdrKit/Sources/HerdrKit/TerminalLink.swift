import Foundation

public enum WebURL {
    /// First http/https URL in `text` via NSDataDetector(.link).
    public static func first(in text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector?.firstMatch(in: text, options: [], range: range),
              let url = match.url
        else { return nil }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

public struct WebLinkCollector: Equatable {
    public static let limit = 50
    public private(set) var urls: [URL]

    public init(urls: [URL] = []) {
        self.urls = urls
    }

    /// Dedup by absoluteString. Append. If count > limit, drop the oldest.
    public mutating func add(_ url: URL) {
        let key = url.absoluteString
        if urls.contains(where: { $0.absoluteString == key }) { return }
        urls.append(url)
        if urls.count > Self.limit {
            urls.removeFirst(urls.count - Self.limit)
        }
    }
}

public struct VisibleTextExtractor {
    public enum Event: Equatable {
        case line(String)
        case osc8(String)
    }

    private enum Mode {
        case ground
        case escape
        case csi
        case osc
        case oscST
    }

    private var mode: Mode = .ground
    private var visible = Data()
    private var oscBody = Data()
    private var pendingCR = false

    public init() {}

    /// Feed a PTY chunk. Return events for completed lines and OSC 8 payloads.
    public mutating func consume(_ data: Data) -> [Event] {
        var events: [Event] = []
        for byte in data {
            process(byte, events: &events)
        }
        return events
    }

    private mutating func process(_ byte: UInt8, events: inout [Event]) {
        if pendingCR {
            pendingCR = false
            if byte != 0x0A {
                visible.removeAll()
            }
        }

        switch mode {
        case .ground:
            switch byte {
            case 0x1B:
                mode = .escape
            case 0x0A:
                emitLine(&events)
            case 0x0D:
                pendingCR = true
            case 0x00...0x1F, 0x7F:
                break
            default:
                visible.append(byte)
            }
        case .escape:
            switch byte {
            case 0x5B: // [
                mode = .csi
            case 0x5D: // ]
                mode = .osc
                oscBody.removeAll()
            default:
                mode = .ground
            }
        case .csi:
            if byte >= 0x40, byte <= 0x7E {
                mode = .ground
            }
        case .osc:
            if byte == 0x07 {
                finishOSC(&events)
            } else if byte == 0x1B {
                mode = .oscST
            } else {
                oscBody.append(byte)
            }
        case .oscST:
            if byte == 0x5C { // \
                finishOSC(&events)
            } else {
                oscBody.append(0x1B)
                if byte == 0x07 {
                    finishOSC(&events)
                } else {
                    oscBody.append(byte)
                    mode = .osc
                }
            }
        }
    }

    private mutating func finishOSC(_ events: inout [Event]) {
        let body = String(decoding: oscBody, as: UTF8.self)
        oscBody.removeAll()
        mode = .ground
        guard body.hasPrefix("8;") else { return }
        let rest = body.dropFirst(2)
        guard let semi = rest.firstIndex(of: ";") else { return }
        let uri = String(rest[rest.index(after: semi)...])
        if !uri.isEmpty {
            events.append(.osc8(uri))
        }
    }

    private mutating func emitLine(_ events: inout [Event]) {
        let line = String(decoding: visible, as: UTF8.self)
        visible.removeAll()
        if !line.isEmpty {
            events.append(.line(line))
        }
    }
}
