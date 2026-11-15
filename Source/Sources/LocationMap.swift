import AppKit
import MapKit
import SwiftUI

struct LocationMap: NSViewRepresentable {
    let position: GeoPoint
    let bearing: Double
    let trail: [GeoPoint]
    let pickingStart: Bool
    let following: Bool
    let focusRequest: Int
    let zoomRequest: Int
    let previewPlace: SearchPlace?
    let chooseStart: (GeoPoint) -> Void
    let regionChanged: (MKCoordinateRegion) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.appearance = NSAppearance(named: .darkAqua)
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsCompass = false
        map.showsZoomControls = false
        map.showsScale = false
        map.delegate = context.coordinator
        map.setRegion(
            MKCoordinateRegion(center: position.coordinate, latitudinalMeters: 950, longitudinalMeters: 950),
            animated: false
        )

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.delegate = context.coordinator
        map.addGestureRecognizer(click)
        map.addAnnotation(context.coordinator.marker)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        let old = coordinator.configuration
        coordinator.configuration = self
        if old.position != position {
            coordinator.marker.coordinate = position.coordinate
        }
        if let marker = map.view(for: coordinator.marker) as? HeadingMarker, marker.bearing != bearing {
            marker.bearing = bearing
        }
        if old.trail.last != trail.last || old.trail.count != trail.count {
            coordinator.drawTrail(on: map)
        }
        if old.previewPlace != previewPlace {
            map.removeAnnotation(coordinator.searchMarker)
            if let previewPlace {
                coordinator.searchMarker.coordinate = previewPlace.point.coordinate
                coordinator.searchMarker.title = previewPlace.name
                map.addAnnotation(coordinator.searchMarker)
                map.setCenter(previewPlace.point.coordinate, animated: true)
            }
        }
        let zoomSteps = zoomRequest - old.zoomRequest
        if zoomSteps != 0 {
            let rect = map.visibleMapRect
            let factor = pow(0.60, Double(zoomSteps))
            let width = rect.width * factor
            let height = rect.height * factor
            if width > 250 && width < MKMapRect.world.width * 0.90 {
                map.setVisibleMapRect(
                    MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height),
                    animated: false
                )
            }
        } else if focusRequest != old.focusRequest || (following && !old.following) {
            map.setCenter(position.coordinate, animated: true)
        } else if following && old.position != position {
            let pixel = map.convert(position.coordinate, toPointTo: map)
            let bounds = map.bounds
            if !bounds.isEmpty && !bounds.insetBy(dx: bounds.width * 0.20, dy: bounds.height * 0.20).contains(pixel) {
                map.setCenter(position.coordinate, animated: false)
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var configuration: LocationMap
        let marker = MKPointAnnotation()
        let searchMarker = MKPointAnnotation()
        var overlay: MKPolyline?

        init(_ configuration: LocationMap) {
            self.configuration = configuration
            marker.coordinate = configuration.position.coordinate
        }

        @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard configuration.pickingStart, let map = recognizer.view as? MKMapView else { return }
            let coordinate = map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            configuration.chooseStart(GeoPoint(coordinate))
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            configuration.pickingStart
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            DispatchQueue.main.async { [weak self] in
                self?.configuration.regionChanged(region)
            }
        }

        func drawTrail(on map: MKMapView) {
            if let overlay {
                map.removeOverlay(overlay)
                self.overlay = nil
            }

            let coordinates = configuration.trail.map(\.coordinate)
            guard coordinates.count > 1 else { return }
            let path = MKPolyline(coordinates: coordinates, count: coordinates.count)
            overlay = path
            map.addOverlay(path, level: .aboveRoads)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let path = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: path)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderer.lineWidth = 3.5
            renderer.strokeColor = NSColor(red: 0.82, green: 0.95, blue: 0.40, alpha: 0.9)
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation === searchMarker {
                let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "search-place")
                view.markerTintColor = .systemOrange
                return view
            }
            guard annotation === marker else { return nil }
            let view = HeadingMarker(annotation: annotation, reuseIdentifier: "heading")
            view.bearing = configuration.bearing
            return view
        }
    }
}

private final class HeadingMarker: MKAnnotationView {
    override var isFlipped: Bool { false }
    var bearing = 0.0 {
        didSet { needsDisplay = true }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame.size = CGSize(width: 56, height: 56)
        canShowCallout = false
        isEnabled = false
        displayPriority = .required
        collisionMode = .circle
        setAccessibilityLabel("模擬位置")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        let lime = NSColor(red: 0.85, green: 0.96, blue: 0.43, alpha: 1)
        let dark = NSColor(red: 0.07, green: 0.12, blue: 0.08, alpha: 1)
        lime.withAlphaComponent(0.20).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        dark.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 10, dy: 10)).fill()
        lime.setStroke()
        let rim = NSBezierPath(ovalIn: bounds.insetBy(dx: 11, dy: 11))
        rim.lineWidth = 1.5
        rim.stroke()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radians = bearing * .pi / 180
        func rotate(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(
                x: center.x + x * cos(radians) + y * sin(radians),
                y: center.y - x * sin(radians) + y * cos(radians)
            )
        }
        let arrow = NSBezierPath()
        arrow.move(to: rotate(0, 12))
        arrow.line(to: rotate(8, -8))
        arrow.line(to: rotate(0, -4))
        arrow.line(to: rotate(-8, -8))
        arrow.close()
        lime.setFill()
        arrow.fill()
    }
}
