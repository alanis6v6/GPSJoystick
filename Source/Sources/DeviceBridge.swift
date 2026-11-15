import Foundation

struct DeviceEvent: Decodable {
    let event: String
    let label: String?
    let serial: String?
    let message: String?
}

@MainActor
final class DeviceBridge {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var inputClosed = false

    var onEvent: ((DeviceEvent) -> Void)?
    var onEnd: (() -> Void)?

    private static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPSJoystick", isDirectory: true)
    }

    private static var pythonURL: URL {
        supportDirectory.appendingPathComponent("python/bin/python3")
    }

    static var isInstalled: Bool {
        let marker = supportDirectory.appendingPathComponent("iphone-support-ready")
        return FileManager.default.isExecutableFile(atPath: pythonURL.path)
            && FileManager.default.fileExists(atPath: marker.path)
    }

    func start(expectedSerial: String?) throws {
        guard let script = Bundle.main.url(forResource: "iphone_bridge", withExtension: "py") else {
            throw CocoaError(.fileNoSuchFile)
        }

        process.executableURL = Self.pythonURL
        process.arguments = ["-I", "-u", script.path] + (expectedSerial.map { [$0] } ?? [])
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            DispatchQueue.main.async {
                self?.receive(data)
            }
        }
    }

    func send(_ action: String, point: GeoPoint? = nil) throws {
        var command: [String: Any] = ["action": action]
        if let point {
            command["latitude"] = point.latitude
            command["longitude"] = point.longitude
        }
        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        try? input.fileHandleForWriting.close()
    }

    func terminate() {
        closeInput()
        if process.isRunning {
            process.terminate()
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            onEnd?()
            return
        }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            if let event = try? JSONDecoder().decode(DeviceEvent.self, from: line) {
                onEvent?(event)
            }
            buffer.removeSubrange(...newline)
        }
    }
}
