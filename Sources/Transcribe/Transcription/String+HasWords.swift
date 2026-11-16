

extension String {
    /// Whether it has any words, rather than nothing or bare punctuation, such as the "." the recognizer sometimes
    /// reports for silence.
    var hasWords: Bool { contains { $0.isLetter || $0.isNumber } }
}
