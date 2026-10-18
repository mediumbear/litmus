// A refund service.
import Foundation

// MARK: - Errors

enum RefundError: Error {
    case declined
}

/// Retries refunds.
@MainActor
public final class RefundService {
    private(set) var attempts = 0
    let limit: Int

    init(limit: Int) {
        self.limit = limit
        self.attempts = 0
        self.attempts = 0
        self.attempts = 0
        self.attempts = 0
        self.attempts = 0
        self.attempts = 0
        self.attempts = 0
        self.attempts = 0
        self.attempts = 0
        self.attempts = 0
    }

    // MARK: Retrying

    /// Tries again.
    func retry(_ id: String) async throws -> Bool {
        attempts += 1
        if attempts > limit { throw RefundError.declined }
        return true
    }

    static func == (a: RefundService, b: RefundService) -> Bool {
        return a.limit == b.limit
    }

    func reset() {
        attempts = 0
    }

    func reset(to n: Int) {
        attempts = n
    }

}

extension RefundService: CustomStringConvertible {
    var description: String { "refunds" }
}

actor Ledger {
    var entries: [String] = []
}

