import Foundation

extension String {
    /// True if the string contains any Han (Chinese) characters.
    var containsHan: Bool {
        range(of: "\\p{Han}", options: .regularExpression) != nil
    }

    /// Tone-marked pinyin via the system ICU transliterator (on-device,
    /// no network). Returns nil for text with no Chinese characters.
    /// Heteronyms occasionally get the wrong reading — fine for a
    /// learning aid, not a substitute for a dictionary.
    var pinyin: String? {
        guard containsHan else { return nil }
        return applyingTransform(.toLatin, reverse: false)
    }
}
