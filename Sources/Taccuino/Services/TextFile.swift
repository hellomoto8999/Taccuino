import Foundation

enum LineEnding: String, Codable, CaseIterable, Identifiable {
    case crlf
    case lf
    case cr

    var id: String { rawValue }

    var separator: String {
        switch self {
        case .crlf: return "\r\n"
        case .lf: return "\n"
        case .cr: return "\r"
        }
    }

    var displayName: String {
        switch self {
        case .crlf: return "Windows (CRLF)"
        case .lf: return "Unix (LF)"
        case .cr: return "Macintosh (CR)"
        }
    }
}

enum TextEncoding: String, Codable, CaseIterable, Identifiable {
    case utf8
    case utf8BOM
    case utf16LE
    case utf16BE
    case ansi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return L.t("UTF-8 con BOM", "UTF-8 with BOM")
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .ansi: return "ANSI"
        }
    }

    /// Codifica il testo (già normalizzato a LF) e indica se alcuni caratteri sono stati sostituiti.
    func encode(_ text: String) -> (data: Data, lossy: Bool)? {
        switch self {
        case .utf8:
            guard let data = text.data(using: .utf8) else { return nil }
            return (data, false)
        case .utf8BOM:
            guard let body = text.data(using: .utf8) else { return nil }
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(body)
            return (data, false)
        case .utf16LE:
            guard let body = text.data(using: .utf16LittleEndian) else { return nil }
            var data = Data([0xFF, 0xFE])
            data.append(body)
            return (data, false)
        case .utf16BE:
            guard let body = text.data(using: .utf16BigEndian) else { return nil }
            var data = Data([0xFE, 0xFF])
            data.append(body)
            return (data, false)
        case .ansi:
            if let strict = text.data(using: .windowsCP1252, allowLossyConversion: false) {
                return (strict, false)
            }
            if let lossy = text.data(using: .windowsCP1252, allowLossyConversion: true) {
                return (lossy, true)
            }
            return nil
        }
    }
}

struct DecodedText {
    let text: String
    let encoding: TextEncoding
    let lineEnding: LineEnding
}

enum TextFileError: LocalizedError {
    case tooLarge(Int)
    case unreadable(String)
    case notText
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .tooLarge(let max):
            let mb = max / (1024 * 1024)
            return L.t("Il file supera il limite di \(mb) MB di Taccuino.",
                       "The file is larger than Taccuino's \(mb) MB limit.")
        case .unreadable(let reason):
            return reason
        case .notText:
            return L.t("Il file non sembra un documento di testo.",
                       "The file does not appear to be a text document.")
        case .cannotEncode:
            return L.t("Non è stato possibile codificare il testo con la codifica scelta.",
                       "The text could not be encoded with the selected encoding.")
        }
    }
}

enum TextFile {
    static let maxBytes = 64 * 1024 * 1024

    static func read(from url: URL) throws -> DecodedText {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if let size = values?.fileSize, size > maxBytes {
            throw TextFileError.tooLarge(maxBytes)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw TextFileError.unreadable(error.localizedDescription)
        }
        guard !data.isEmpty else {
            return DecodedText(text: "", encoding: .utf8, lineEnding: .crlf)
        }

        var text: String
        var encoding: TextEncoding

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8BOM
            text = String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LE
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BE
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
        } else if let utf16 = detectBOMLessUTF16(data) {
            encoding = utf16.encoding
            text = utf16.text
        } else if let utf8 = String(data: data, encoding: .utf8) {
            encoding = .utf8
            text = utf8
        } else if let ansi = String(data: data, encoding: .windowsCP1252) {
            encoding = .ansi
            text = ansi
        } else if let latin = String(data: data, encoding: .isoLatin1) {
            encoding = .ansi
            text = latin
        } else {
            throw TextFileError.notText
        }

        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let lineEnding = detectLineEnding(in: text)
        text = normalizeNewlines(text)
        return DecodedText(text: text, encoding: encoding, lineEnding: lineEnding)
    }

    static func write(_ text: String, to url: URL, encoding: TextEncoding, lineEnding: LineEnding) throws -> Bool {
        let converted = normalizeNewlines(text).replacingOccurrences(of: "\n", with: lineEnding.separator)
        guard let result = encoding.encode(converted) else {
            throw TextFileError.cannotEncode
        }
        try result.data.write(to: url, options: .atomic)
        return result.lossy
    }

    static func detectLineEnding(in text: String) -> LineEnding {
        if text.contains("\r\n") { return .crlf }
        if text.contains("\n") { return .lf }
        if text.contains("\r") { return .cr }
        return .crlf
    }

    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Rilevamento euristico per file UTF-16 privi di BOM, come fa il Blocco note.
    private static func detectBOMLessUTF16(_ data: Data) -> (text: String, encoding: TextEncoding)? {
        guard data.count >= 4, data.count % 2 == 0 else { return nil }
        let sampleCount = min(data.count, 4096)
        var evenZeros = 0
        var oddZeros = 0
        var index = 0
        while index < sampleCount {
            if data[index] == 0 { evenZeros += 1 }
            if index + 1 < sampleCount, data[index + 1] == 0 { oddZeros += 1 }
            index += 2
        }
        let pairs = sampleCount / 2
        guard pairs > 0 else { return nil }
        let evenRatio = Double(evenZeros) / Double(pairs)
        let oddRatio = Double(oddZeros) / Double(pairs)
        if oddRatio > 0.35 && evenRatio < 0.1 {
            if let text = String(data: data, encoding: .utf16LittleEndian), isMostlyPrintable(text) {
                return (text, .utf16LE)
            }
        }
        if evenRatio > 0.35 && oddRatio < 0.1 {
            if let text = String(data: data, encoding: .utf16BigEndian), isMostlyPrintable(text) {
                return (text, .utf16BE)
            }
        }
        return nil
    }

    private static func isMostlyPrintable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var printable = 0
        var total = 0
        for scalar in text.unicodeScalars.prefix(2048) {
            total += 1
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F) {
                printable += 1
            }
        }
        return total > 0 && Double(printable) / Double(total) > 0.9
    }
}
