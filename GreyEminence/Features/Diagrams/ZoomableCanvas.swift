import AppKit
import SwiftUI

/// SwiftUI content of a known size in a native scroll view that zooms and
/// pans: the mouse wheel, a pinch or the zoom controls to zoom, two-finger
/// scroll or a drag on empty space to pan. Content smaller than the pane
/// sits centred.
///
/// The content is scaled in SwiftUI and the scroll view only scrolls, rather
/// than using the scroll view's own magnification: a magnified clip view
/// hands SwiftUI clicks at unscaled positions, so a click selected whatever
/// sat at that point in the 100% drawing.
struct ZoomableCanvas<Content: View>: NSViewRepresentable {
    let contentSize: CGSize
    /// The current magnification; set it to zoom, read it to show it.
    @Binding var zoom: CGFloat
    /// Bump to fit the content to the pane.
    let fitRequest: Int
    let content: Content

    static var minZoom: CGFloat { 0.2 }
    static var maxZoom: CGFloat { 3 }

    init(contentSize: CGSize, zoom: Binding<CGFloat>, fitRequest: Int, @ViewBuilder content: () -> Content) {
        self.contentSize = contentSize
        self._zoom = zoom
        self.fitRequest = fitRequest
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator(zoom: $zoom) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let scroll = ZoomingScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.onZoom = { [weak coordinator] factor, point in
            coordinator?.zoom(by: factor, at: point)
        }

        let host = NSHostingView(rootView: ScaledContent(content: content, size: contentSize, zoom: zoom))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: contentSize.scaled(zoom))
        scroll.documentView = host

        // Drag on the canvas to pan; a click without movement still
        // reaches the nodes underneath.
        let pan = NSPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delaysPrimaryMouseButtonEvents = false
        scroll.contentView.addGestureRecognizer(pan)

        coordinator.scrollView = scroll
        coordinator.host = host
        coordinator.applied = zoom
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.zoom = $zoom
        coordinator.content = content
        coordinator.contentSize = contentSize
        if coordinator.lastFitRequest != fitRequest {
            coordinator.lastFitRequest = fitRequest
            coordinator.render()
            // After layout, so the pane has its final size.
            DispatchQueue.main.async { coordinator.fit() }
        } else if abs(coordinator.applied - zoom) > 0.001 {
            let visible = scroll.contentView.bounds
            coordinator.apply(zoom, keeping: CGPoint(x: visible.midX, y: visible.midY))
        } else {
            coordinator.render()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var zoom: Binding<CGFloat>
        weak var scrollView: NSScrollView?
        weak var host: NSHostingView<ScaledContent<Content>>?
        var content: Content?
        var contentSize: CGSize = .zero
        /// The magnification the document is drawn at.
        var applied: CGFloat = 1
        var lastFitRequest: Int?
        private var panOrigin: CGPoint = .zero

        init(zoom: Binding<CGFloat>) {
            self.zoom = zoom
        }

        /// Redraws the content at the applied magnification.
        func render() {
            guard let host, let content else { return }
            host.rootView = ScaledContent(content: content, size: contentSize, zoom: applied)
            let size = contentSize.scaled(applied)
            if host.frame.size != size { host.frame.size = size }
        }

        /// Zooms to `level`, keeping the document point under `point` (in
        /// clip-view coordinates) where it is on screen.
        func apply(_ level: CGFloat, keeping point: CGPoint) {
            guard let scroll = scrollView else { return }
            let clip = scroll.contentView
            let level = min(max(level, ZoomableCanvas.minZoom), ZoomableCanvas.maxZoom)
            let offset = CGPoint(x: point.x - clip.bounds.minX, y: point.y - clip.bounds.minY)
            let ratio = level / applied
            applied = level
            render()
            let origin = CGPoint(x: point.x * ratio - offset.x, y: point.y * ratio - offset.y)
            clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            if abs(zoom.wrappedValue - level) > 0.001 { zoom.wrappedValue = level }
        }

        func zoom(by factor: CGFloat, at point: CGPoint) {
            apply(applied * factor, keeping: point)
        }

        /// The whole diagram in view, never enlarged past 100%.
        func fit() {
            guard let scroll = scrollView else { return }
            let visible = scroll.contentView.frame.size
            guard visible.width > 0, visible.height > 0, contentSize.width > 0, contentSize.height > 0 else { return }
            let scale = min(visible.width / contentSize.width, visible.height / contentSize.height, 1)
            apply(scale * 0.95, keeping: .zero)
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(CGRect(origin: .zero, size: scroll.contentView.bounds.size)).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        @objc func pan(_ gesture: NSPanGestureRecognizer) {
            guard let scroll = scrollView else { return }
            let clip = scroll.contentView
            switch gesture.state {
            case .began:
                panOrigin = clip.bounds.origin
                NSCursor.closedHand.push()
            case .changed:
                let delta = gesture.translation(in: clip)
                // The content follows the pointer, so the visible area moves
                // the other way — in flipped and unflipped coordinates alike.
                let origin = CGPoint(x: panOrigin.x - delta.x, y: panOrigin.y - delta.y)
                clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin)
                scroll.reflectScrolledClipView(clip)
            case .ended, .cancelled, .failed:
                NSCursor.pop()
            default:
                break
            }
        }
    }
}

/// The content at its natural size, scaled from the top-left corner into a
/// frame of the scaled size — SwiftUI maps clicks through the scale.
struct ScaledContent<Content: View>: View {
    let content: Content
    let size: CGSize
    let zoom: CGFloat

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
    }
}

/// Zooms with the mouse wheel, a pinch, or ⌘ with a trackpad scroll, about
/// the pointer; a plain trackpad scroll still pans.
private final class ZoomingScrollView: NSScrollView {
    var onZoom: ((CGFloat, CGPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        // A notched mouse wheel reports whole lines; a trackpad or a
        // free-spinning wheel reports precise deltas.
        let isMouseWheel = !event.hasPreciseScrollingDeltas
        guard isMouseWheel || event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let steps = isMouseWheel ? event.scrollingDeltaY : event.scrollingDeltaY / 10
        onZoom?(pow(1.1, steps), pointer(event))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification, pointer(event))
    }

    private func pointer(_ event: NSEvent) -> CGPoint {
        contentView.convert(event.locationInWindow, from: nil)
    }
}

/// Keeps a document smaller than the pane centred instead of pinned to a
/// corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}

private extension CGSize {
    func scaled(_ factor: CGFloat) -> CGSize {
        CGSize(width: width * factor, height: height * factor)
    }
}
