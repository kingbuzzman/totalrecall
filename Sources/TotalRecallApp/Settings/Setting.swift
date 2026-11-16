import SwiftUI

/// A setting in `AppSettings.file`, for a view, as `@AppStorage` is for user defaults: `$name` binds a control to it,
/// and a view that reads it is redrawn when it changes.
@propertyWrapper
struct Setting<Value: Sendable>: Sendable {
    private let key: String
    private let defaultValue: Value
    private let read: @Sendable (Any) -> Value?
    private let write: @Sendable (Value) -> Any

    /// A setting stored as it is: a Bool, an Int or a String.
    init(wrappedValue: Value, _ key: String) {
        self.init(key, defaultValue: wrappedValue, read: { $0 as? Value }, write: { $0 })
    }

    /// A setting stored as its raw value, such as an enumeration's name.
    init(wrappedValue: Value, _ key: String) where Value: RawRepresentable, Value.RawValue == String {
        self.init(
            key,
            defaultValue: wrappedValue,
            read: { ($0 as? String).flatMap(Value.init) },
            write: { $0.rawValue }
        )
    }

    private init(
        _ key: String,
        defaultValue: Value,
        read: @escaping @Sendable (Any) -> Value?,
        write: @escaping @Sendable (Value) -> Any
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.read = read
        self.write = write
    }

    var wrappedValue: Value {
        get { AppSettings.file[key].flatMap(read) ?? defaultValue }
        nonmutating set { AppSettings.file[key] = write(newValue) }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
