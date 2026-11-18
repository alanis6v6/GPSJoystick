import AppKit
import Combine
import Foundation
import MapKit

enum LinkPhase: Equatable {
    case preview, connecting, ready, syncing, restoring, disconnecting, failed
}

enum MotionState {
    case awaitingDirection, moving, paused
}

@MainActor
final class SimulatorModel: ObservableObject {
    @Published private(set) var navigation = NavigationState()
    @Published private(set) var input = StickInput.neutral
    @Published private(set) var phase = LinkPhase.preview
    @Published private(set) var deviceLabel = ""
    @Published private(set) var connectionError: String?
    @Published private(set) var needsSetup = !DeviceBridge.isInstalled
    @Published private(set) var restoreUnconfirmed = false
    @Published private(set) var mapFocusRequest = 0
    @Published private(set) var zoomRequest = 0
    @Published private(set) var motion = MotionState.awaitingDirection
    @Published private(set) var targetSpeed = 5.0
    @Published private(set) var simulatingSteps = false
    @Published private(set) var stride = 0.75
    @Published private(set) var simulatedStepCount = 0
    @Published private(set) var destination: GeoPoint?
    @Published private(set) var route: [GeoPoint] = []
    @Published private(set) var routing = false
    @Published private(set) var routeIsStraight = false
    @Published var pickingStart = false
    @Published var pickingDestination = false
    @Published var following = true

    let stepBroadcaster = StepBroadcaster()
    private var stepSimulation = StepSimulation()
    private var pointer = StickInput.neutral
    private var keys: Set<UInt16> = []
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var bridge: DeviceBridge?
    private var setInFlight = false
    private var pendingPoint: GeoPoint?
    private var lastSentAt = -Double.infinity
    private var deviceSerial: String?
    private var pendingRestoreSerial: String?
    private var quitCompletion: (@MainActor @Sendable () -> Void)?
    private var motionTimer: AnyCancellable?
    private var directions: MKDirections?
    private var routeRequest = 0
    private var routeTail = 0.0
    private var startAfterRouting = false

    init() {
        motionTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    var currentSpeed: Double { motion == .moving && !routing ? targetSpeed : 0 }

    /// Meters left to the destination along the planned route.
    var destinationRemaining: Double {
        guard let destination else { return 0 }
        return navigation.position.distance(to: route.first ?? destination) + routeTail
    }

    func setTargetSpeed(_ speed: Double) {
        guard speed != targetSpeed else { return }
        tick()
        if !(speed > 0 && speed <= 8) {
            flushSteps()
        }
        targetSpeed = speed
    }

    func setStepSimulation(_ enabled: Bool) {
        guard enabled != simulatingSteps else { return }
        tick()
        if !enabled {
            flushSteps()
            stepSimulation.resetStrideProgress()
        }
        simulatingSteps = enabled
    }

    func setStride(_ meters: Double) {
        guard meters.isFinite, (0.3...1.5).contains(meters), meters != stride else { return }
        tick()
        stride = meters
    }

    func toggleMotion() {
        guard motion != .awaitingDirection, !routing else { return }
        tick()
        if motion == .moving {
            flushSteps()
        }
        motion = motion == .moving ? .paused : .moving
    }

    func setPointer(_ input: StickInput) {
        pointer = input
        updateInput(steering: input.isDeflected)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let key = event.keyCode
        guard (123...126).contains(key) else { return false }
        if event.type == .keyUp {
            guard keys.remove(key) != nil else { return false }
            updateInput(steering: false)
        } else {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(event.window?.firstResponder is NSTextView) else { return false }
            if !event.isARepeat && keys.insert(key).inserted {
                updateInput(steering: !pointer.isDeflected)
            }
        }
        return true
    }

    func releaseControls() {
        pointer = .neutral
        keys.removeAll()
        updateInput(steering: false)
    }

    private func updateInput(steering: Bool) {
        let east = Double((keys.contains(124) ? 1 : 0) - (keys.contains(123) ? 1 : 0))
        let north = Double((keys.contains(126) ? 1 : 0) - (keys.contains(125) ? 1 : 0))
        let newInput = pointer.isDeflected ? pointer : StickInput(east: east, north: north)
        if input != newInput {
            input = newInput
        }

        guard steering, newInput.isDeflected else { return }
        if destination != nil {
            // Manual steering takes over from the destination.
            tick()
            dropDestination()
        }
        let bearing = newInput.bearing
        guard motion == .awaitingDirection || navigation.bearing != bearing else { return }
        // Account for movement in the previous direction up to this input event.
        tick()
        if navigation.bearing != bearing {
            navigation.bearing = bearing
        }
        if motion == .awaitingDirection {
            motion = .moving
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = now - lastTick
        let elapsed = min(0.20, interval)
        lastTick = now

        if interval > 1 {
            flushSteps()
        }
        if motion == .moving && targetSpeed > 0 && elapsed > 0 && !routing {
            var next = navigation
            var arrived = false
            if destination != nil {
                var remainingRoute = route
                arrived = next.advance(along: &remainingRoute, speedKPH: targetSpeed, elapsed: elapsed)
                if remainingRoute.count != route.count {
                    route = remainingRoute
                    routeTail = Self.length(of: remainingRoute)
                }
            } else {
                next.advance(speedKPH: targetSpeed, elapsed: elapsed)
            }
            if simulatingSteps && targetSpeed <= 8 {
                let batch = stepSimulation.advance(
                    meters: next.distance - navigation.distance, elapsed: elapsed, stride: stride, now: .now
                )
                if simulatedStepCount != stepSimulation.total {
                    simulatedStepCount = stepSimulation.total
                }
                if let batch {
                    stepBroadcaster.enqueue(batch)
                }
            }
            navigation = next
            if phase == .syncing {
                pendingPoint = next.position
            }
            if arrived {
                flushSteps()
                dropDestination()
                motion = .paused
            }
        }

        if phase == .syncing && now - lastSentAt >= 0.25 {
            flushPosition(at: now)
        }
    }

    private func flushSteps() {
        if let batch = stepSimulation.finish() {
            stepBroadcaster.enqueue(batch)
        }
    }

    func setStart(_ point: GeoPoint) {
        guard point.isValid else { return }
        releaseControls()
        if motion == .moving {
            tick()
            flushSteps()
            motion = .paused
        }
        stepSimulation.resetStrideProgress()
        navigation.setStart(point)
        pickingStart = false
        // A new start point clears the destination.
        dropDestination()
        if phase == .syncing {
            pendingPoint = point
            flushPosition(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    func setDestination(_ point: GeoPoint) {
        guard point.isValid else { return }
        pickingDestination = false
        releaseControls()
        tick()
        guard navigation.position.distance(to: point) >= 1 else { return }
        destination = point
        planRoute(startWhenReady: true)
    }

    private func planRoute(startWhenReady: Bool) {
        guard let destination else { return }
        if motion == .moving {
            flushSteps()
            motion = .paused
        }
        directions?.cancel()
        routeRequest += 1
        let request = routeRequest
        route = []
        routeTail = 0
        routeIsStraight = false
        routing = true
        startAfterRouting = startWhenReady

        let query = MKDirections.Request()
        query.source = MKMapItem(placemark: MKPlacemark(coordinate: navigation.position.coordinate))
        query.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        query.transportType = targetSpeed > 25 ? .automobile : .walking
        let directions = MKDirections(request: query)
        self.directions = directions
        directions.calculate { [weak self] response, _ in
            var points: [GeoPoint] = []
            if let line = response?.routes.first?.polyline {
                let buffer = UnsafeBufferPointer(start: line.points(), count: line.pointCount)
                points = buffer.map { GeoPoint($0.coordinate) }.filter(\.isValid)
            }
            Task { @MainActor [weak self] in
                self?.finishRoute(request, points: points)
            }
        }
    }

    private func finishRoute(_ request: Int, points: [GeoPoint]) {
        guard request == routeRequest, routing, let destination else { return }
        tick()
        directions = nil
        routing = false
        // Without a road route, head straight for the destination.
        routeIsStraight = points.isEmpty
        var path: [GeoPoint] = []
        for point in points where path.last.map({ $0.distance(to: point) >= 0.5 }) ?? true {
            path.append(point)
        }
        if path.last.map({ $0.distance(to: destination) >= 0.5 }) ?? true {
            path.append(destination)
        } else {
            path[path.count - 1] = destination
        }
        route = path
        routeTail = Self.length(of: path)
        if let first = path.first, navigation.position.distance(to: first) > 0.01 {
            navigation.bearing = navigation.position.bearing(to: first)
        }
        if startAfterRouting {
            motion = .moving
        } else if motion == .awaitingDirection {
            motion = .paused
        }
    }

    private func dropDestination() {
        directions?.cancel()
        directions = nil
        routeRequest += 1
        destination = nil
        route = []
        routeTail = 0
        routing = false
        routeIsStraight = false
    }

    private static func length(of path: [GeoPoint]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    func clearDestination() {
        guard destination != nil else { return }
        tick()
        if motion == .moving {
            flushSteps()
            motion = .paused
        }
        dropDestination()
    }

    func recenterMap() {
        mapFocusRequest += 1
    }

    func zoomMap(by steps: Int) {
        zoomRequest += steps
    }

    func refreshDeviceSupport() {
        let missing = !DeviceBridge.isInstalled
        guard needsSetup != missing else { return }
        needsSetup = missing
        if !missing && phase == .failed && !restoreUnconfirmed {
            phase = .preview
            connectionError = nil
        }
    }

    func setupDeviceSupport() {
        guard let setup = Bundle.main.url(forResource: "Setup-iPhone", withExtension: "command"),
              NSWorkspace.shared.open(setup) else {
            phase = .failed
            connectionError = "無法開啟安裝程式。請在終端機執行 Setup-iPhone.command。"
            return
        }
    }

    func connect() {
        guard bridge == nil else { return }
        let installed = DeviceBridge.isInstalled
        guard installed else {
            needsSetup = true
            phase = .failed
            connectionError = "請先安裝 iPhone 連線元件。安裝完成後，再按「連接 iPhone」。"
            return
        }

        let connection = DeviceBridge()
        connection.onEvent = { [weak self, weak connection] event in
            guard let self, let connection, self.bridge === connection else { return }
            self.receive(event)
        }
        connection.onEnd = { [weak self, weak connection] in
            guard let self, let connection, self.bridge === connection else { return }
            let message = self.phase == .disconnecting && !self.restoreUnconfirmed
                ? nil : "iPhone 連線已中斷。"
            self.endConnection(error: message)
        }
        phase = .connecting
        connectionError = nil
        bridge = connection
        do {
            try connection.start(expectedSerial: pendingRestoreSerial)
        } catch {
            endConnection(error: "無法啟動 iPhone 連線元件。請重新執行安裝。")
        }
    }

    func startSync() {
        guard phase == .ready && !restoreUnconfirmed else { return }
        phase = .syncing
        pendingPoint = navigation.position
        flushPosition(at: ProcessInfo.processInfo.systemUptime)
    }

    func restore() {
        guard phase == .ready || phase == .syncing else { return }
        pendingPoint = nil
        phase = .restoring
        send("clear")
    }

    func disconnect() {
        guard let bridge, phase != .disconnecting else { return }
        pendingPoint = nil
        if phase == .connecting {
            bridge.terminate()
            endConnection()
        } else {
            phase = .disconnecting
            send("disconnect")
        }
    }

    func prepareToQuit(_ complete: @escaping @MainActor @Sendable () -> Void) -> Bool {
        tick()
        flushSteps()
        stepBroadcaster.persist()
        if motion == .moving {
            motion = .paused
        }
        guard let connection = bridge else { return false }
        if phase == .connecting {
            disconnect()
            return false
        }
        quitCompletion = complete
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak connection] in
            guard let self, let connection, self.bridge === connection else { return }
            connection.terminate()
            self.endConnection(error: "iPhone 連線未正常結束。")
        }
        return true
    }

    private func send(_ action: String, point: GeoPoint? = nil) {
        do {
            try bridge?.send(action, point: point)
        } catch {
            endConnection(error: "無法傳送指令。請確認 iPhone 的 USB 連線。")
        }
    }

    private func flushPosition(at now: Double) {
        guard phase == .syncing, !setInFlight, let point = pendingPoint else { return }
        pendingPoint = nil
        setInFlight = true
        restoreUnconfirmed = true
        pendingRestoreSerial = deviceSerial
        lastSentAt = now
        send("set", point: point)
    }

    private func receive(_ event: DeviceEvent) {
        switch event.event {
        case "ready":
            guard phase == .connecting, let serial = event.serial else { return }
            phase = .ready
            needsSetup = false
            deviceSerial = serial
            deviceLabel = event.label ?? "iPhone"
        case "set":
            setInFlight = false
        case "cleared":
            restoreUnconfirmed = false
            pendingRestoreSerial = nil
            if phase == .restoring {
                phase = .ready
            }
        case "closed":
            endConnection()
        case "error":
            if event.message?.contains("Setup-iPhone.command") == true {
                needsSetup = true
            }
            endConnection(error: event.message ?? "iPhone 連線失敗。")
        default:
            break
        }
    }

    private func endConnection(error: String? = nil) {
        bridge?.closeInput()
        bridge = nil
        setInFlight = false
        pendingPoint = nil
        deviceLabel = ""
        deviceSerial = nil
        connectionError = error
        phase = error == nil ? .preview : .failed
        let completion = quitCompletion
        quitCompletion = nil
        if let completion {
            DispatchQueue.main.async(execute: completion)
        }
    }
}
