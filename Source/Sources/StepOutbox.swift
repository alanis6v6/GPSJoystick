import Foundation

struct StepOutbox {
    private let file: URL
    private(set) var batches: [StepBatch]

    init(file: URL) throws {
        self.file = file
        do {
            batches = try JSONDecoder().decode([StepBatch].self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            batches = []
        }
    }

    mutating func append(_ batch: StepBatch) throws {
        try save(batches + [batch])
    }

    mutating func acknowledge(_ data: Data) throws -> Bool {
        guard data.count == 16 else { return false }
        if let first = batches.first, first.acknowledgement == data {
            try save(Array(batches.dropFirst()))
        }
        // A repeat acknowledgement can arrive after the first one was processed.
        return !batches.contains { $0.acknowledgement == data }
    }

    private mutating func save(_ updated: [StepBatch]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        batches = updated
    }
}
