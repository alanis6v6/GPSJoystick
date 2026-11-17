import CoreLocation
import Foundation

struct GeoPoint: Equatable {
    var latitude: Double
    var longitude: Double

    static let taipei = GeoPoint(latitude: 25.03396, longitude: 121.56447)
    private static let earthRadius = 6_371_008.8

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && CLLocationCoordinate2DIsValid(coordinate)
    }

    func moved(meters: Double, bearing: Double) -> GeoPoint {
        let angularDistance = meters / Self.earthRadius
        let startLatitude = latitude * .pi / 180
        let startLongitude = longitude * .pi / 180
        let direction = bearing * .pi / 180
        let latitudeSine = sin(startLatitude) * cos(angularDistance)
            + cos(startLatitude) * sin(angularDistance) * cos(direction)
        let endLatitude = asin(min(1, max(-1, latitudeSine)))
        let endLongitude = startLongitude + atan2(
            sin(direction) * sin(angularDistance) * cos(startLatitude),
            cos(angularDistance) - sin(startLatitude) * sin(endLatitude)
        )
        let longitudeDegrees = (endLongitude * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
        return GeoPoint(latitude: endLatitude * 180 / .pi, longitude: longitudeDegrees)
    }

    func bearing(to other: GeoPoint) -> Double {
        let startLatitude = latitude * .pi / 180
        let endLatitude = other.latitude * .pi / 180
        let longitudeDelta = (other.longitude - longitude) * .pi / 180
        let east = sin(longitudeDelta) * cos(endLatitude)
        let north = cos(startLatitude) * sin(endLatitude)
            - sin(startLatitude) * cos(endLatitude) * cos(longitudeDelta)
        return (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    func distance(to other: GeoPoint) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

struct StickInput: Equatable {
    static let neutral = StickInput(east: 0, north: 0)

    let east: Double
    let north: Double

    init(east: Double, north: Double) {
        let scale = max(1, hypot(east, north))
        self.east = east / scale
        self.north = north / scale
    }

    var isDeflected: Bool {
        hypot(east, north) > 0.12
    }

    var bearing: Double {
        (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

struct NavigationState {
    private(set) var position = GeoPoint.taipei
    var bearing = 0.0
    private(set) var distance = 0.0
    private(set) var trail = [GeoPoint.taipei]

    mutating func setStart(_ point: GeoPoint) {
        guard point.isValid else { return }
        position = point
        distance = 0
        trail = [point]
    }

    mutating func advance(speedKPH: Double, elapsed: Double) {
        let meters = speedKPH / 3.6 * elapsed
        guard meters > 0 else { return }
        move(meters: meters)
    }

    private mutating func move(meters: Double) {
        position = position.moved(meters: meters, bearing: bearing)
        distance += meters

        if let last = trail.last, last.distance(to: position) >= 2 {
            extendTrail(position)
        }
    }

    private mutating func extendTrail(_ point: GeoPoint) {
        trail.append(point)
        if trail.count > 1200 {
            trail.removeFirst(200)
        }
    }

    /// Moves through the waypoints in `route`, removing each one as it is reached.
    /// Returns true once the last waypoint has been reached.
    mutating func advance(along route: inout [GeoPoint], speedKPH: Double, elapsed: Double) -> Bool {
        var budget = speedKPH / 3.6 * elapsed
        guard budget > 0 else { return false }
        while let target = route.first {
            let remaining = position.distance(to: target)
            if remaining > 0.01 {
                bearing = position.bearing(to: target)
            }
            guard remaining <= budget else {
                move(meters: budget)
                return false
            }
            // Land exactly on the waypoint, then spend what is left of this step on the next one.
            position = target
            distance += remaining
            budget -= remaining
            if trail.last != target {
                extendTrail(target)
            }
            route.removeFirst()
        }
        return true
    }
}
