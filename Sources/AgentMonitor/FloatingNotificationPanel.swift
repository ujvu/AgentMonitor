import Cocoa

/// A floating, non-activating panel that appears when an agent needs attention.
///
/// The panel shows:
/// - App icon and name on the left
/// - Signal reason text in the middle
/// - Screenshot thumbnail on the right
///
/// The entire panel is clickable — clicking anywhere activates the target
/// app and dismisses the notification. The panel also auto-dismisses after
/// a timeout (default 30 seconds).
final class FloatingNotificationPanel: NSPanel {

    private let autoDismissInterval: TimeInterval = 30.0
    private var dismissTimer: Timer?
    private var currentAppBundleId: String?
    private var notifView: NotificationContentView!

    // Notification positioning
    private let panelWidth: CGFloat = 460
    private let panelHeight: CGFloat = 140

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        configurePanel()
    }

    private func configurePanel() {
        // Key properties: float above everything, don't steal focus
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.worksWhenModal = true

        // Create the content view
        let frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        let view = NotificationContentView(frame: frame)
        notifView = view
        self.contentView = view

        // Set up click handling
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        view.addGestureRecognizer(clickGesture)
    }

    // MARK: - Show Notification

    func showNotification(appName: String, appBundleId: String, reason: String, screenshot: NSImage?) {
        self.currentAppBundleId = appBundleId

        DispatchQueue.main.async { [self] in
            // Get app icon
            let appIcon = self.getAppIcon(bundleId: appBundleId)

            // Update content
            notifView.configure(appName: appName, appIcon: appIcon, reason: reason, screenshot: screenshot)

            // Position in top-right corner of screen
            self.positionTopRight()

            // Animate in
            self.orderFrontRegardless()
            self.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.animator().alphaValue = 1.0
            })

            // Start auto-dismiss timer
            dismissTimer?.invalidate()
            dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissInterval, repeats: false) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [self] in
            dismissTimer?.invalidate()
            dismissTimer = nil

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.animator().alphaValue = 0.0
            }, completionHandler: {
                self.orderOut(nil)
            })
        }
    }

    // MARK: - Actions

    @objc private func handleClick() {
        guard let bundleId = currentAppBundleId else { return }
        AppActivator.activate(bundleId: bundleId)
        dismiss()
    }

    // MARK: - Positioning

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - panelWidth - 20
        let y = screenFrame.maxY - panelHeight - 20
        self.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    // MARK: - App Icon

    private func getAppIcon(bundleId: String) -> NSImage? {
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).first {
            return app.icon
        }
        return NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
    }
}

// MARK: - Content View

/// Custom view that draws the notification content.
class NotificationContentView: NSView {

    private var appName: String = ""
    private var appIcon: NSImage?
    private var reason: String = ""
    private var screenshot: NSImage?

    private let cardCornerRadius: CGFloat = 12
    private let iconSize: CGFloat = 36
    private let thumbWidth: CGFloat = 80
    private let thumbHeight: CGFloat = 60

    override func draw(_ dirtyRect: NSRect) {
        // Draw card background
        let cardPath = NSBezierPath(roundedRect: bounds, xRadius: cardCornerRadius, yRadius: cardCornerRadius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        cardPath.fill()

        // Draw subtle border
        NSColor.separatorColor.withAlphaComponent(0.3).set()
        cardPath.lineWidth = 1
        cardPath.stroke()

        // Draw subtle red accent bar on the left
        let accentRect = NSRect(x: 0, y: 0, width: 4, height: bounds.height)
        let accentPath = NSBezierPath(roundedRect: accentRect, xRadius: 2, yRadius: 2)
        NSColor.systemRed.setFill()
        accentPath.fill()

        // Layout positions
        let padding: CGFloat = 16
        let iconX = padding + 4  // +4 for accent bar
        let iconY = bounds.midY - iconSize / 2

        // Draw app icon
        if let icon = appIcon {
            let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
            icon.draw(in: iconRect)
        }

        // Draw app name
        let nameRect = NSRect(
            x: iconX + iconSize + 10,
            y: bounds.height - 50,
            width: bounds.width - iconX - iconSize - thumbWidth - 30,
            height: 20
        )
        let nameAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
        ]
        (appName as NSString).draw(in: nameRect, withAttributes: nameAttr)

        // Draw reason text
        let reasonRect = NSRect(
            x: iconX + iconSize + 10,
            y: 25,
            width: bounds.width - iconX - iconSize - thumbWidth - 30,
            height: bounds.height - 75
        )
        let reasonAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let reasonParagraph = NSMutableParagraphStyle()
        reasonParagraph.lineBreakMode = .byTruncatingTail
        let reasonText = NSAttributedString(string: reason, attributes: reasonAttr)
        reasonText.draw(in: reasonRect)

        // Draw screenshot thumbnail on the right
        if let shot = screenshot {
            let thumbRect = NSRect(
                x: bounds.width - thumbWidth - padding,
                y: bounds.midY - thumbHeight / 2,
                width: thumbWidth,
                height: thumbHeight
            )
            // Draw rounded rect clip
            let clipPath = NSBezierPath(roundedRect: thumbRect, xRadius: 6, yRadius: 6)
            NSGraphicsContext.current?.saveGraphicsState()
            clipPath.addClip()
            // Draw image aspect-filled
            let imgAspect = shot.size.height / shot.size.width
            let thumbAspect = thumbRect.height / thumbRect.width
            var drawRect = thumbRect
            if imgAspect > thumbAspect {
                drawRect.size.height = thumbRect.width * imgAspect
                drawRect.origin.y = thumbRect.midY - drawRect.height / 2
            } else {
                drawRect.size.width = thumbRect.height / imgAspect
                drawRect.origin.x = thumbRect.midX - drawRect.width / 2
            }
            shot.draw(in: drawRect)
            NSGraphicsContext.current?.restoreGraphicsState()

            // Draw border around thumbnail
            NSColor.separatorColor.withAlphaComponent(0.3).set()
            clipPath.lineWidth = 1
            clipPath.stroke()
        } else {
            // Draw placeholder
            let placeholderRect = NSRect(
                x: bounds.width - thumbWidth - padding,
                y: bounds.midY - thumbHeight / 2,
                width: thumbWidth,
                height: thumbHeight
            )
            let clipPath = NSBezierPath(roundedRect: placeholderRect, xRadius: 6, yRadius: 6)
            NSColor.quaternaryLabelColor.setFill()
            clipPath.fill()
        }

        // Draw "点击跳转" hint at bottom
        let hintRect = NSRect(
            x: iconX + iconSize + 10,
            y: 8,
            width: 200,
            height: 14
        )
        let hintAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        ("点击此处跳转到 " + appName).draw(in: hintRect, withAttributes: hintAttr)
    }

    func configure(appName: String, appIcon: NSImage?, reason: String, screenshot: NSImage?) {
        self.appName = appName
        self.appIcon = appIcon
        self.reason = reason
        self.screenshot = screenshot
        self.needsDisplay = true
    }
}
