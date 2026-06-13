import Foundation
import ImageIO

enum RatingStore {

    // MARK: - Read

    static func readRating(from url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return readSidecarRating(for: url)
        }
        // 1. CGImageMetadata — xmp:Rating tag (most reliable for embedded XMP)
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Rating" as CFString),
           let val = CGImageMetadataTagCopyValue(tag) {
            if let r = (val as? NSNumber)?.intValue { return max(0, min(5, r)) }
            if let s = val as? String, let r = Int(s) { return max(0, min(5, r)) }
        }
        // 2. Sidecar .xmp
        return readSidecarRating(for: url)
    }

    private static func readSidecarRating(for url: URL) -> Int {
        let xmpURL = url.deletingPathExtension().appendingPathExtension("xmp")
        guard let data = try? Data(contentsOf: xmpURL),
              let str = String(data: data, encoding: .utf8) else { return 0 }
        for pattern in [#"xmp:Rating="(\d+)""#, #"xmp:Rating='(\d+)'"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
                  let range = Range(match.range(at: 1), in: str),
                  let rating = Int(str[range]) else { continue }
            return max(0, min(5, rating))
        }
        return 0
    }

    // MARK: - Write

    static func writeRating(_ rating: Int, to url: URL) throws {
        do {
            try writeEmbedded(rating: rating, to: url)
        } catch {
            try writeSidecar(rating: rating, for: url)
        }
    }

    // Embeds xmp:Rating into the image file using CGImageDestinationCopyImageSource
    // (lossless — avoids re-encoding) then atomically replaces the original.
    private static func writeEmbedded(rating: Int, to url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw RatingError.cannotRead }

        let meta = CGImageMetadataCreateMutable()
        let ns = "http://ns.adobe.com/xap/1.0/" as CFString
        let prefix = "xmp" as CFString
        CGImageMetadataRegisterNamespaceForPrefix(meta, ns, prefix, nil)
        if let tag = CGImageMetadataTagCreate(ns, prefix, "Rating" as CFString,
                                               .string, "\(rating)" as CFTypeRef) {
            CGImageMetadataSetTagWithPath(meta, nil, "xmp:Rating" as CFString, tag)
        }

        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).memoriaptmp")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL, type, 1, nil) else {
            throw RatingError.cannotWrite
        }
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: meta,
                                      kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(dest, source, opts as CFDictionary, nil) else {
            throw RatingError.cannotWrite
        }
        try FileManager.default.replaceItem(at: url, withItemAt: tmpURL,
                                            backupItemName: nil,
                                            options: .usingNewMetadataOnly,
                                            resultingItemURL: nil)
    }

    // Writes an XMP sidecar file (<photo>.xmp) for formats where embedding is not supported.
    private static func writeSidecar(rating: Int, for url: URL) throws {
        let xmpURL = url.deletingPathExtension().appendingPathExtension("xmp")
        let content = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Memoriap">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmp:Rating="\(rating)"/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try content.write(to: xmpURL, atomically: true, encoding: .utf8)
    }

    enum RatingError: LocalizedError {
        case cannotRead, cannotWrite
        var errorDescription: String? {
            switch self {
            case .cannotRead:  return "별점을 읽을 수 없습니다."
            case .cannotWrite: return "별점을 저장할 수 없습니다."
            }
        }
    }
}
