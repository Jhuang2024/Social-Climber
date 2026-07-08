import Foundation

/// A tiny, schema-agnostic JSON file store scoped to whatever container
/// `locator` resolves to. This type has no idea LockedInFit exists: it just
/// reads and writes Codable values to named files. `CrossAppIntegrationManager`
/// is the only thing that knows which filenames and schemas those are.
struct SharedContextStore {
    let locator: SharedContainerLocating

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Writes atomically: `Data.write(options: .atomic)` writes to a
    /// temporary file in the same directory and then replaces the
    /// destination, so a reader on the other side never observes a
    /// partially-written file.
    func write<T: Encodable>(_ value: T, to filename: String) {
        guard let container = locator.containerURL() else { return }
        guard let data = try? Self.makeEncoder().encode(value) else { return }
        let url = container.appendingPathComponent(filename)
        try? data.write(to: url, options: .atomic)
    }

    /// Reads the raw bytes and hands them to `decode`, so each schema can
    /// supply its own defensive `JSONDecoder` configuration (e.g. a
    /// tolerant date strategy) without this type needing to know about it.
    /// Returns `nil` for a missing file, an unreadable one, or whatever
    /// `decode` itself treats as corrupted.
    func read<T>(_ type: T.Type, from filename: String, decode: (Data) -> T?) -> T? {
        guard let container = locator.containerURL() else { return nil }
        let url = container.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}
