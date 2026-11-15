import Combine
import CoreBluetooth
import HealthKit
import OSLog

@MainActor
final class StepReceiver: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {
    @Published private(set) var status = "請先在 Mac 開啟「藍牙同步至 iPhone」。"
    @Published private(set) var active = false
    @Published private(set) var authorizing = false
    @Published private(set) var saving = false
    @Published private(set) var savedSteps = 0

    private let health = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)
    private let serviceID = CBUUID(string: StepBluetooth.serviceID)
    private let batchID = CBUUID(string: StepBluetooth.batchID)
    private let acknowledgementID = CBUUID(string: StepBluetooth.acknowledgementID)
    private let availableID = CBUUID(string: StepBluetooth.availableID)
    private let savedBatchKey = "lastSavedStepBatch"
    private let logger = Logger(subsystem: "local.gpsjoystick.steps", category: "Bluetooth")
    private var central: CBCentralManager?
    private var mac: CBPeripheral?
    private var batchCharacteristic: CBCharacteristic?
    private var acknowledgementCharacteristic: CBCharacteristic?
    private var availabilityCharacteristic: CBCharacteristic?
    private var reading = false
    private var acknowledging = false
    private var signaled = false
    private var nextAction: Task<Void, Never>?
    private var retryCount = 0

    func start() async {
        guard !active, !authorizing, !saving else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "此裝置無法使用 HealthKit。"
            return
        }
        authorizing = true
        defer { authorizing = false }
        if health.authorizationStatus(for: stepType) == .notDetermined {
            do {
                try await health.requestAuthorization(toShare: [stepType], read: [])
            } catch {
                status = "無法取得健康資料授權。請在「健康」檢查 App 權限。"
                return
            }
        }
        guard health.authorizationStatus(for: stepType) == .sharingAuthorized else {
            status = "請在「健康」的 App 權限中開啟此 App 的步數寫入。"
            return
        }
        active = true
        status = "正在啟動藍牙…"
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    func stop() {
        end("同步已停止。")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central, active else { return }
        switch central.state {
        case .poweredOn:
            scan()
        case .poweredOff:
            resetTransfer()
            mac = nil
            status = "請開啟 iPhone 藍牙。開啟後會繼續尋找 Mac。"
        case .unauthorized:
            end("請在 iPhone 設定允許此 App 使用藍牙。")
        case .unsupported:
            end("此裝置不支援低功耗藍牙。")
        case .resetting, .unknown:
            resetTransfer()
            mac = nil
            status = "正在等待 iPhone 藍牙啟動…"
        @unknown default:
            end("藍牙目前無法使用。")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, active, central.isScanning, mac == nil,
              (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) != false else { return }
        mac = peripheral
        central.stopScan()
        status = "正在連線到 GPS 搖桿…"
        central.connect(peripheral)
        schedule(after: .seconds(15)) {
            self.retryConnection("藍牙連線逾時")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === mac, active else { return }
        status = "已連線，正在準備步數同步…"
        schedule(after: .seconds(15)) {
            self.retryConnection("取得 Mac 的步數服務逾時")
        }
        peripheral.delegate = self
        peripheral.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === mac, active else { return }
        retryConnection("無法連線到 GPS 搖桿", error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === mac, active else { return }
        retryConnection("與 Mac 的連線已中斷", error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === mac, active else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            retryConnection("找不到 GPS 搖桿的步數服務", error: error)
            return
        }
        peripheral.discoverCharacteristics([batchID, acknowledgementID, availableID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === mac, active else { return }
        guard error == nil, let batch = service.characteristics?.first(where: { $0.uuid == batchID }),
              let ack = service.characteristics?.first(where: { $0.uuid == acknowledgementID }) else {
            retryConnection("無法取得 GPS 搖桿的步數服務欄位", error: error)
            return
        }
        batchCharacteristic = batch
        acknowledgementCharacteristic = ack
        availabilityCharacteristic = service.characteristics?.first { $0.uuid == availableID }
        if let availabilityCharacteristic {
            peripheral.setNotifyValue(true, for: availabilityCharacteristic)
        } else {
            readBatch()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === mac, active, characteristic === availabilityCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            retryConnection("無法訂閱步數通知", error: error)
            return
        }
        readBatch()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === mac, active else { return }
        if characteristic === availabilityCharacteristic {
            guard error == nil else { return }
            signaled = true
            readBatch()
            return
        }
        guard characteristic === batchCharacteristic, reading else { return }
        reading = false
        nextAction?.cancel()
        guard error == nil, let data = characteristic.value else {
            retryConnection("無法讀取步數", error: error)
            return
        }
        guard !data.isEmpty else {
            retryCount = 0
            status = availabilityCharacteristic == nil
                ? "已連線。請更新 Mac App 以支援背景同步。"
                : "已連線，可在背景接收新的模擬步數。"
            if signaled {
                readBatch()
            } else if availabilityCharacteristic == nil {
                schedule(after: .seconds(2)) { self.readBatch() }
            }
            return
        }
        guard let decoded = try? JSONDecoder().decode(StepBatch.self, from: data) else {
            end("無法解析 Mac 傳來的步數資料（\(data.count) 位元組）。請確認兩端已更新。")
            return
        }
        let batch = decoded.adjustedForClockGap
        guard batch.isValid else {
            end("Mac 傳來的步數超出有效範圍（\(batch.count) 步）。")
            return
        }
        if UserDefaults.standard.string(forKey: savedBatchKey) == batch.id.uuidString {
            acknowledge(batch)
            return
        }
        status = "正在寫入「健康」…"
        saving = true
        let transferCharacteristic = characteristic
        Task {
            defer {
                saving = false
                if batchCharacteristic !== transferCharacteristic { readBatch() }
            }
            do {
                let sample = HKQuantitySample(
                    type: stepType,
                    quantity: HKQuantity(unit: .count(), doubleValue: Double(batch.count)),
                    start: batch.start,
                    end: batch.end,
                    metadata: [
                        HKMetadataKeyWasUserEntered: true,
                        HKMetadataKeySyncIdentifier: batch.id.uuidString,
                        HKMetadataKeySyncVersion: 1,
                        "GPSJoystickSimulated": true
                    ]
                )
                try await health.save(sample)
                UserDefaults.standard.set(batch.id.uuidString, forKey: savedBatchKey)
                savedSteps += batch.count
                if peripheral === mac, active, batchCharacteristic === transferCharacteristic {
                    acknowledge(batch)
                }
            } catch {
                if peripheral === mac, active, batchCharacteristic === transferCharacteristic {
                    end("無法寫入「健康」：\(error.localizedDescription)")
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === mac, active, characteristic === acknowledgementCharacteristic else { return }
        acknowledging = false
        guard error == nil else {
            retryConnection("步數已寫入，Mac 尚未確認", error: error)
            return
        }
        retryCount = 0
        readBatch()
    }

    private func readBatch() {
        guard active, !reading, !saving, !acknowledging, let mac, let batchCharacteristic,
              availabilityCharacteristic?.isNotifying != false else { return }
        reading = true
        signaled = false
        mac.readValue(for: batchCharacteristic)
        schedule(after: .seconds(30)) { self.retryConnection("讀取步數逾時") }
    }

    private func acknowledge(_ batch: StepBatch) {
        guard active, let mac, let acknowledgementCharacteristic else { return }
        acknowledging = true
        mac.writeValue(batch.acknowledgement, for: acknowledgementCharacteristic, type: .withResponse)
        schedule(after: .seconds(30)) { self.retryConnection("確認步數寫入逾時") }
    }

    private func scan() {
        guard active, let central, central.state == .poweredOn, mac == nil else { return }
        if !central.isScanning {
            central.scanForPeripherals(withServices: [serviceID])
        }
        if retryCount == 0 {
            status = "正在尋找附近的 GPS 搖桿…"
        }
        schedule(after: .seconds(15)) {
            self.status = "仍在尋找 GPS 搖桿。請確認 Mac 已喚醒且已開啟「藍牙同步至 iPhone」。"
        }
    }

    private func retryConnection(_ message: String, error: Error? = nil) {
        guard active, let central else { return }
        let previous = mac
        mac = nil
        resetTransfer()
        if let previous, previous.state != .disconnected, central.state == .poweredOn {
            central.cancelPeripheralConnection(previous)
        }
        let detail = error.map { error in
            let systemError = error as NSError
            return "（\(systemError.localizedDescription)，\(systemError.domain) \(systemError.code)）"
        } ?? ""
        logger.notice("\(message, privacy: .public)\(detail, privacy: .public)")
        status = "\(message)\(detail)。正在重試，請確認 Mac 已開啟步數藍牙同步。"
        let delay = 1 << retryCount
        retryCount = min(retryCount + 1, 3)
        schedule(after: .seconds(delay)) { self.scan() }
    }

    private func schedule(after duration: Duration, action: @escaping @MainActor () -> Void) {
        nextAction?.cancel()
        nextAction = Task {
            do {
                try await Task.sleep(for: duration)
                action()
            } catch {
                return
            }
        }
    }

    private func end(_ message: String) {
        central?.stopScan()
        if let mac {
            central?.cancelPeripheralConnection(mac)
        }
        mac = nil
        central = nil
        resetTransfer()
        retryCount = 0
        active = false
        status = message
    }

    private func resetTransfer() {
        nextAction?.cancel()
        nextAction = nil
        batchCharacteristic = nil
        acknowledgementCharacteristic = nil
        availabilityCharacteristic = nil
        reading = false
        acknowledging = false
        signaled = false
    }
}
