import Foundation

/// A failure that is nothing but what to tell the user, which is how every part of totalrecall reports one.
package struct MessageError: LocalizedError {
    package let errorDescription: String?

    package init(_ description: String) {
        errorDescription = description
    }
}
