import Foundation

public enum Text {
    /// Canonical form for user-entered text: Unicode NFC, trimmed, and empty mapped to nil.
    ///
    /// NFC matters for Korean: Hangul can arrive precomposed (NFC) or decomposed (NFD), e.g. when
    /// pasted from file names. Swift's `==` treats both as equal but SQLite compares bytes, so
    /// without this an account named "신한카드" could be both a duplicate and not a duplicate.
    public static func normalize(_ string: String?) -> String? {
        guard let string else { return nil }
        let trimmed = string.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
