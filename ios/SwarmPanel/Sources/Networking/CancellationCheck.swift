import Foundation

extension Error {
    /// True for both Swift structured-concurrency cancellation and the
    /// underlying URLSession cancellation SwiftUI's `.task { }` triggers
    /// whenever the attached view is torn down mid-request (switching tabs
    /// and back, a view re-rendering, pull-to-refresh interrupted, etc.).
    /// These are normal lifecycle events, not failures — no view model
    /// should ever surface one as a user-facing error message.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        let nsError = self as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        if let apiError = self as? APIError, case .network(let underlying) = apiError {
            return underlying.isCancellation
        }
        return false
    }
}
