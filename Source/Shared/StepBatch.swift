import Foundation

enum StepBluetooth {
    static let serviceID = "63933C2E-E1F5-491C-93D9-2E6370B19D01"
    static let batchID = "63933C2E-E1F5-491C-93D9-2E6370B19D02"
    static let acknowledgementID = "63933C2E-E1F5-491C-93D9-2E6370B19D03"
    static let availableID = "63933C2E-E1F5-491C-93D9-2E6370B19D04"
}

struct StepBatch: Codable, Equatable {
    static let interval: TimeInterval = 10
    let id: UUID
    let start: Date
    let end: Date
    let count: Int

    var acknowledgement: Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    var isValid: Bool {
        (1...10_000).contains(count) && start < end
            && (end.timeIntervalSince(start) <= 60)
    }

    var adjustedForClockGap: StepBatch {
        guard !(0 < end.timeIntervalSince(start) && end.timeIntervalSince(start) <= 60) else { return self }
        // Older versions could include idle time. Keep the batch ID, step count and end time.
        return StepBatch(id: id, start: end.addingTimeInterval(-Self.interval), end: end, count: count)
    }
}
