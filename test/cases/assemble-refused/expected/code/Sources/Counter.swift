import Foundation

// MARK: - Counting

struct Counter {
    var count = 0
    var step = 2

    mutating func add() {
        count += step
    }

    mutating func reset() {
        count = 0
    }
}

func report(_ counter: Counter) -> String {
    return "count: \(counter.count)"
}
