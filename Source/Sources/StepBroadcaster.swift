import Combine
import CoreBluetooth
import Foundation

@MainActor
final class StepBroadcaster: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var status = "藍牙同步已關閉"
    @Published private(set) var pendingSteps = 0
    @Published private(set) var storageError: String?

    private let file = URL.applicationSupportDirectory
        .appending(path: "GPSJoystick/step-outbox.json")
    private var outbox: StepOutbox?
    private var unsaved: [StepBatch] = []
    private var manager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var availability: CBMutableCharacteristic?
    private var notificationPending = false
    private var reads: [UUID: Data] = [:]
    private let serviceID = CBUUID(string: StepBluetooth.serviceID)
    private let batchID = CBUUID(string: StepBluetooth.batchID)
    private let acknowledgementID = CBUUID(string: StepBluetooth.acknowledgementID)
    private let availableID = CBUUID(string: StepBluetooth.availableID)

    override init() {
        super.init()
        persist()
    }

    func enqueue(_ batch: StepBatch) {
        unsaved.append(batch)
        persist()
        notifyAvailability()
    }

    func persist() {
        do {
            if outbox == nil {
                outbox = try StepOutbox(file: file)
            }
            while let batch = unsaved.first {
                try outbox?.append(batch)
                unsaved.removeFirst()
            }
            storageError = nil
        } catch {
            storageError = "無法儲存模擬步數。請確認磁碟空間與資料夾權限。"
        }
        updatePendingSteps()
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value {
            persist()
            status = "正在啟動藍牙…"
            manager = CBPeripheralManager(delegate: self, queue: nil, options: [
                CBPeripheralManagerOptionShowPowerAlertKey: false
            ])
        } else {
            manager?.stopAdvertising()
            manager?.removeAllServices()
            manager = nil
            characteristic = nil
            availability = nil
            notificationPending = false
            reads.removeAll()
            status = "藍牙同步已關閉"
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        characteristic = nil
        availability = nil
        notificationPending = false
        reads.removeAll()
        switch peripheral.state {
        case .poweredOn:
            let batch = CBMutableCharacteristic(
                type: batchID, properties: .read, value: nil,
                permissions: [.readable, .readEncryptionRequired]
            )
            let ack = CBMutableCharacteristic(
                type: acknowledgementID, properties: .write, value: nil,
                permissions: [.writeable, .writeEncryptionRequired]
            )
            let available = CBMutableCharacteristic(
                type: availableID, properties: [.indicate, .indicateEncryptionRequired], value: nil, permissions: []
            )
            let service = CBMutableService(type: serviceID, primary: true)
            service.characteristics = [batch, ack, available]
            characteristic = batch
            availability = available
            peripheral.add(service)
        case .poweredOff:
            status = "請開啟 Mac 藍牙"
        case .unauthorized:
            status = "請在系統設定允許 GPS 搖桿使用藍牙"
        case .unsupported:
            status = "這台 Mac 無法使用低功耗藍牙"
        default:
            status = "正在等待藍牙…"
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager else { return }
        guard error == nil else {
            status = "無法啟動藍牙服務，請重新開啟步數同步"
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceID],
            CBAdvertisementDataLocalNameKey: "GPSJoystick"
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager else { return }
        status = error == nil ? "等待 iPhone 配套 App 接收" : "無法廣播藍牙服務，請重新開啟步數同步"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager, request.characteristic.uuid == characteristic?.uuid else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        let central = request.central.identifier
        if request.offset == 0 {
            if let batch = outbox?.batches.first {
                reads[central] = try? JSONEncoder().encode(batch.adjustedForClockGap)
            } else {
                reads[central] = Data()
            }
        }
        guard let data = reads[central], request.offset <= data.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = Data(data.dropFirst(request.offset))
        peripheral.respond(to: request, withResult: .success)
        status = data.isEmpty ? "iPhone 已連線，等待模擬步數" : "iPhone 已讀取步數，等待寫入確認"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let request = requests.first else { return }
        guard peripheral === manager, requests.count == 1, request.offset == 0,
              request.characteristic.uuid == acknowledgementID, let data = request.value else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        do {
            guard try outbox?.acknowledge(data) == true else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                return
            }
            reads.removeValue(forKey: request.central.identifier)
            updatePendingSteps()
            status = "iPhone 已確認寫入步數"
            peripheral.respond(to: request, withResult: .success)
        } catch {
            storageError = "無法更新步數同步佇列。重新連線可再試一次。"
            peripheral.respond(to: request, withResult: .unlikelyError)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic.uuid == availableID else { return }
        status = "iPhone 已連線"
        notifyAvailability()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic.uuid == availableID else { return }
        reads.removeValue(forKey: central.identifier)
        if availability?.subscribedCentrals?.isEmpty != false {
            status = "等待 iPhone 配套 App 接收"
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager, notificationPending else { return }
        notifyAvailability()
    }

    private func notifyAvailability() {
        guard let manager, let availability, availability.subscribedCentrals?.isEmpty == false,
              outbox?.batches.isEmpty == false else {
            notificationPending = false
            return
        }
        notificationPending = !manager.updateValue(Data([1]), for: availability, onSubscribedCentrals: nil)
    }

    private func updatePendingSteps() {
        pendingSteps = (outbox?.batches.reduce(0) { $0 + $1.count } ?? 0)
            + unsaved.reduce(0) { $0 + $1.count }
    }
}
