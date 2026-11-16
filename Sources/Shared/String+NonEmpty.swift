extension String {
    /// The string, or nil when it is empty.
    package var nonEmpty: String? { isEmpty ? nil : self }
}
