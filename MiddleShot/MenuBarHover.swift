import Cocoa

/// The hover bubble's content: one module's dropdown section, borrowed while
/// the menu is closed (a view can only live in one place at a time).
final class HoverPopoverContent: NSViewController {
    /// The pointer moved into or out of the bubble — moving into it keeps it
    /// open, so its graphs can be pointed at too.
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private(set) var isMouseInside = false

    private final class TrackingView: NSView {
        weak var owner: HoverPopoverContent?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            owner?.isMouseInside = true
            owner?.onEnter?()
        }

        override func mouseExited(with event: NSEvent) {
            owner?.isMouseInside = false
            owner?.onExit?()
        }
    }

    override func loadView() {
        let view = TrackingView()
        view.owner = self
        self.view = view
    }

    func embed(_ section: NSView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        section.removeFromSuperview()
        section.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(section)
        NSLayoutConstraint.activate([
            section.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            section.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            section.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            section.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
        ])
        isMouseInside = false
        view.layoutSubtreeIfNeeded()
        // The view keeps its last frame between bubbles; size it to this
        // section or a short one inherits a tall one's height.
        let size = view.fittingSize
        view.setFrameSize(size)
        preferredContentSize = size
    }

    /// Hands the section back so the dropdown can take it again.
    func release() {
        view.subviews.forEach { $0.removeFromSuperview() }
        isMouseInside = false
    }
}
