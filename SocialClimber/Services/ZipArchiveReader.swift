import Foundation
import Compression

/// A minimal, read-only ZIP reader — just enough to pull the JSON files out
/// of an Instagram "Download Your Information" export without any
/// third-party dependency. Supports stored and deflate entries, plus the
/// ZIP64 extensions Meta uses for large archives. Reads from disk via
/// FileHandle so a multi-gigabyte export (media included) never has to fit
/// in memory — only the individual entries actually requested are inflated.
struct ZipArchiveReader {
    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    enum ZipError: LocalizedError {
        case notAZipFile
        case corrupt(String)
        case unsupportedCompression(UInt16)

        var errorDescription: String? {
            switch self {
            case .notAZipFile: "That file isn't a zip archive."
            case .corrupt(let what): "The export zip looks corrupt (\(what))."
            case .unsupportedCompression(let method): "Unsupported zip compression method \(method)."
            }
        }
    }

    let url: URL
    let entries: [Entry]
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        let fileSize = try handle.seekToEnd()
        entries = try Self.readCentralDirectory(handle: handle, fileSize: fileSize)
    }

    func close() {
        try? handle.close()
    }

    /// Inflates and returns a single entry's bytes.
    func data(for entry: Entry) throws -> Data {
        // The central directory's offset points at the local file header;
        // its name/extra field lengths can differ from the central copy, so
        // read them to find where the payload actually starts.
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30,
              header.readUInt32(at: 0) == 0x04034b50 else {
            throw ZipError.corrupt("bad local header")
        }
        let nameLength = UInt64(header.readUInt16(at: 26))
        let extraLength = UInt64(header.readUInt16(at: 28))
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + nameLength + extraLength)
        guard let compressed = try handle.read(upToCount: Int(entry.compressedSize)),
              compressed.count == Int(entry.compressedSize) else {
            throw ZipError.corrupt("truncated entry data")
        }

        switch entry.compressionMethod {
        case 0: // stored
            return compressed
        case 8: // deflate
            return try Self.inflate(compressed, uncompressedSize: Int(entry.uncompressedSize))
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    // MARK: Central directory

    private static func readCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> [Entry] {
        // Find the End Of Central Directory record by scanning backwards
        // from the end of the file (the record has a variable-length
        // comment, max 64 KB).
        let scanLength = Int(min(fileSize, 66_000))
        try handle.seek(toOffset: fileSize - UInt64(scanLength))
        guard let tail = try handle.read(upToCount: scanLength) else { throw ZipError.notAZipFile }

        var eocdOffsetInTail = -1
        var index = tail.count - 22
        while index >= 0 {
            if tail.readUInt32(at: index) == 0x06054b50 {
                eocdOffsetInTail = index
                break
            }
            index -= 1
        }
        guard eocdOffsetInTail >= 0 else { throw ZipError.notAZipFile }

        var entryCount = UInt64(tail.readUInt16(at: eocdOffsetInTail + 10))
        var centralDirectorySize = UInt64(tail.readUInt32(at: eocdOffsetInTail + 12))
        var centralDirectoryOffset = UInt64(tail.readUInt32(at: eocdOffsetInTail + 16))

        // ZIP64: sentinel values mean the real numbers live in the ZIP64
        // EOCD record, located via a locator that sits just before the EOCD.
        if entryCount == 0xFFFF || centralDirectoryOffset == 0xFFFFFFFF || centralDirectorySize == 0xFFFFFFFF {
            let eocdAbsolute = fileSize - UInt64(scanLength) + UInt64(eocdOffsetInTail)
            guard eocdAbsolute >= 20 else { throw ZipError.corrupt("missing zip64 locator") }
            try handle.seek(toOffset: eocdAbsolute - 20)
            guard let locator = try handle.read(upToCount: 20), locator.count == 20,
                  locator.readUInt32(at: 0) == 0x07064b50 else {
                throw ZipError.corrupt("bad zip64 locator")
            }
            let zip64EOCDOffset = locator.readUInt64(at: 8)
            try handle.seek(toOffset: zip64EOCDOffset)
            guard let record = try handle.read(upToCount: 56), record.count == 56,
                  record.readUInt32(at: 0) == 0x06064b50 else {
                throw ZipError.corrupt("bad zip64 EOCD")
            }
            entryCount = record.readUInt64(at: 32)
            centralDirectorySize = record.readUInt64(at: 40)
            centralDirectoryOffset = record.readUInt64(at: 48)
        }

        try handle.seek(toOffset: centralDirectoryOffset)
        guard let directory = try handle.read(upToCount: Int(centralDirectorySize)),
              directory.count == Int(centralDirectorySize) else {
            throw ZipError.corrupt("truncated central directory")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var offset = 0
        while offset + 46 <= directory.count, entries.count < Int(entryCount) {
            guard directory.readUInt32(at: offset) == 0x02014b50 else { break }
            let method = directory.readUInt16(at: offset + 10)
            var compressedSize = UInt64(directory.readUInt32(at: offset + 20))
            var uncompressedSize = UInt64(directory.readUInt32(at: offset + 24))
            let nameLength = Int(directory.readUInt16(at: offset + 28))
            let extraLength = Int(directory.readUInt16(at: offset + 30))
            let commentLength = Int(directory.readUInt16(at: offset + 32))
            var localHeaderOffset = UInt64(directory.readUInt32(at: offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= directory.count else { throw ZipError.corrupt("truncated name") }
            let nameData = directory.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? ""

            // ZIP64 extra field: any 0xFFFFFFFF values above are replaced,
            // in order, by 8-byte values inside extra field id 0x0001.
            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF {
                var extraOffset = nameStart + nameLength
                // Clamp so a corrupt extraLength throws via the normal
                // bounds instead of trapping on an out-of-range subscript.
                let extraEnd = min(extraOffset + extraLength, directory.count)
                while extraOffset + 4 <= extraEnd {
                    let fieldID = directory.readUInt16(at: extraOffset)
                    let fieldSize = Int(directory.readUInt16(at: extraOffset + 2))
                    if fieldID == 0x0001 {
                        var fieldCursor = extraOffset + 4
                        if uncompressedSize == 0xFFFFFFFF, fieldCursor + 8 <= extraEnd {
                            uncompressedSize = directory.readUInt64(at: fieldCursor)
                            fieldCursor += 8
                        }
                        if compressedSize == 0xFFFFFFFF, fieldCursor + 8 <= extraEnd {
                            compressedSize = directory.readUInt64(at: fieldCursor)
                            fieldCursor += 8
                        }
                        if localHeaderOffset == 0xFFFFFFFF, fieldCursor + 8 <= extraEnd {
                            localHeaderOffset = directory.readUInt64(at: fieldCursor)
                        }
                        break
                    }
                    extraOffset += 4 + fieldSize
                }
            }

            entries.append(Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: Inflate

    /// Raw-deflate decompression via the Compression framework
    /// (`COMPRESSION_ZLIB` is raw deflate, which is exactly what zip stores).
    private static func inflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (inPtr: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    outPtr.bindMemory(to: UInt8.self).baseAddress!, uncompressedSize,
                    inPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else { throw ZipError.corrupt("inflate size mismatch") }
        return output
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(readUInt16(at: offset)) | (UInt32(readUInt16(at: offset + 2)) << 16)
    }

    func readUInt64(at offset: Int) -> UInt64 {
        UInt64(readUInt32(at: offset)) | (UInt64(readUInt32(at: offset + 4)) << 32)
    }
}
