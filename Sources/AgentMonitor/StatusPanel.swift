import Cocoa

/// A "Dynamic Island" style floating status panel.
///
/// When collapsed (mouse not hovering), shows a compact pill with
/// colored dots for each agent's state.
///
/// When expanded (mouse hovering), shows a full card with app icons,
/// names, and state text for each agent.
///
/// Positioned at the top-center of the screen, just below the menu bar.
final class StatusPanel: NSPanel {

    private let collapsedWidth: CGFloat = 220
    private let collapsedHeight: CGFloat = 36
    private let expandedWidth: CGFloat = 300
    private var expandedHeight: CGFloat = 220  // recalculated in init

    private var apps: [AppDefinition] = []
    private var states: [String: WatcherState] = [:]
    private var runningStates: [String: Bool] = [:]
    private var dotViews: [StatusDotView] = []
    private var rowViews: [StatusRowView] = []
    private var container: StatusContainerView!

    private var trackingArea: NSTrackingArea?
    private var isExpanded = false

    init(apps: [AppDefinition]) {
        self.apps = apps
        let frame = NSRect(x: 0, y: 0, width: collapsedWidth, height: collapsedHeight)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.apps = apps
        // Recalculate expanded height based on app count
        let h = 36 + CGFloat(apps.count) * 44 + 12
        self.expandedHeight = h
        configurePanel()
        buildUI()
    }

    // MARK: - Setup

    private func configurePanel() {
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.worksWhenModal = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
    }

    private func buildUI() {
        container = StatusContainerView(
            frame: NSRect(x: 0, y: 0, width: expandedWidth, height: expandedHeight),
            collapsedSize: NSSize(width: collapsedWidth, height: collapsedHeight),
            expandedSize: NSSize(width: expandedWidth, height: expandedHeight),
            appCount: apps.count
        )
        container.apps = apps
        container.panel = self
        self.contentView = container

        // Build dots for collapsed view
        var dotX: CGFloat = 16
        let dotY = collapsedHeight / 2 - 6
        for def in apps {
            let dotFrame = NSRect(x: dotX, y: dotY, width: 12, height: 12)
            let dot = StatusDotView(frame: dotFrame)
            dot.configure(state: .idle, isRunning: false)
            dotViews.append(dot)
            container.addSubview(dot)
            dotX += 18
        }

        // Build rows for expanded view
        var rowY: CGFloat = 12
        for def in apps.reversed() {
            let rowFrame = NSRect(x: 10, y: rowY, width: expandedWidth - 20, height: 40)
            let row = StatusRowView(frame: rowFrame)
            row.configure(definition: def, state: .idle, isRunning: false)
            row.onActivate = { [weak self] bundleId in
                AppActivator.activate(bundleId: bundleId)
                _ = self
            }
            rowViews.append(row)
            container.addSubview(row)
            rowY += 44
        }

        // Set initial collapsed size
        self.setFrame(NSRect(x: 0, y: 0, width: collapsedWidth, height: collapsedHeight), display: true)

        // Set up tracking area on container for hover detection
        let area = NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        container.addTrackingArea(area)

        // Initially hide expanded rows
        rowViews.forEach { $0.isHidden = true }
    }

    // MARK: - Hover

    func mouseEnteredPanel() {
        expand()
    }

    func mouseExitedPanel() {
        collapse()
    }

    private func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        container.setExpanded(true)

        // Hide dots, show rows
        dotViews.forEach { $0.isHidden = true }
        rowViews.forEach { $0.isHidden = false }

        // Animate size change
        var frame = self.frame
        let centerX = frame.midX
        frame.size = NSSize(width: expandedWidth, height: expandedHeight)
        frame.origin.x = centerX - expandedWidth / 2
        self.setFrame(frame, display: true, animate: true)
    }

    private func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        container.setExpanded(false)

        // Show dots, hide rows
        dotViews.forEach { $0.isHidden = false }
        rowViews.forEach { $0.isHidden = true }

        // Animate size change
        var frame = self.frame
        let centerX = frame.midX
        frame.size = NSSize(width: collapsedWidth, height: collapsedHeight)
        frame.origin.x = centerX - collapsedWidth / 2
        self.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Positioning

    func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - collapsedWidth / 2
        let y = screenFrame.maxY - collapsedHeight - 4
        self.setFrame(NSRect(x: x, y: y, width: collapsedWidth, height: collapsedHeight), display: true)
    }

    // MARK: - State Updates

    func updateState(for app: AppDefinition, state: WatcherState, isRunning: Bool) {
        states[app.id] = state
        runningStates[app.id] = isRunning

        for (i, def) in apps.enumerated() where def.id == app.id {
            if i < dotViews.count {
                dotViews[i].configure(state: state, isRunning: isRunning)
            }
            for row in rowViews where row.definition?.id == app.id {
                row.configure(definition: app, state: state, isRunning: isRunning)
            }
        }
    }
}

// MARK: - Container View (draws the pill/card background)

private class StatusContainerView: NSView {
    var apps: [AppDefinition] = []
    weak var panel: StatusPanel?
    private var isExpanded = false
    private let collapsedSize: NSSize
    private let expandedSize: NSSize
    private let appCount: Int

    init(frame: NSRect, collapsedSize: NSSize, expandedSize: NSSize, appCount: Int) {
        self.collapsedSize = collapsedSize
        self.expandedSize = expandedSize
        self.appCount = appCount
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        panel?.mouseEnteredPanel()
    }

    override func mouseExited(with event: NSEvent) {
        panel?.mouseExitedPanel()
    }

    override func draw(_ dirtyRect: NSRect) {
        let cornerRadius: CGFloat = isExpanded ? 16 : collapsedSize.height / 2
        let drawRect = isExpanded ? bounds : NSRect(
            x: (bounds.width - collapsedSize.width) / 2,
            y: 0,
            width: collapsedSize.width,
            height: collapsedSize.height
        )

        let path = NSBezierPath(roundedRect: drawRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.black.withAlphaComponent(0.85).setFill()
        path.fill()

        if isExpanded {
            // Draw title
            let titleRect = NSRect(x: 0, y: bounds.height - 30, width: bounds.width, height: 20)
            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            ]
            ("智能体状态").draw(in: titleRect, withAttributes: titleAttr)

            // Draw separator
            let sepY = bounds.height - 36
            let sepPath = NSBezierPath()
            sepPath.move(to: NSPoint(x: 12, y: sepY))
            sepPath.line(to: NSPoint(x: bounds.width - 12, y: sepY))
            NSColor.white.withAlphaComponent(0.15).set()
            sepPath.lineWidth = 0.5
            sepPath.stroke()
        }
    }
}

// MARK: - Dot View (collapsed mode)

private class StatusDotView: NSView {
    private var dotColor: NSColor = .darkGray
    private var pulseAnimation: CABasicAnimation?

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds)
        dotColor.setFill()
        path.fill()
        // Subtle white border
        NSColor.white.withAlphaComponent(0.2).set()
        path.lineWidth = 0.5
        path.stroke()
    }

    func configure(state: WatcherState, isRunning: Bool) {
        if !isRunning {
            dotColor = NSColor.gray.withAlphaComponent(0.4)
        } else {
            switch state {
            case .idle:
                dotColor = NSColor.systemGray
            case .working:
                dotColor = NSColor.systemGreen
            case .needsAttention:
                dotColor = NSColor.systemRed
            }
        }
        needsDisplay = true
    }
}

// MARK: - Row View (expanded mode)

private class StatusRowView: NSView {
    var definition: AppDefinition?
    var onActivate: ((String) -> Void)?

    private var appName: String = ""
    private var appIcon: NSImage?
    private var stateText: String = ""
    private var dotColor: NSColor = .gray
    private let iconSize: CGFloat = 22

    override func draw(_ dirtyRect: NSRect) {
        // Draw dot
        let dotSize: CGFloat = 8
        let dotRect = NSRect(x: 8, y: bounds.midY - dotSize/2, width: dotSize, height: dotSize)
        NSBezierPath(ovalIn: dotRect).fill()

        // Draw icon
        if let icon = appIcon {
            let iconRect = NSRect(x: 24, y: bounds.midY - iconSize/2, width: iconSize, height: iconSize)
            icon.draw(in: iconRect)
        }

        // Draw name
        let nameRect = NSRect(x: 54, y: bounds.midY + 2, width: 140, height: 16)
        let nameAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        (appName as NSString).draw(in: nameRect, withAttributes: nameAttr)

        // Draw state text
        let stateRect = NSRect(x: 54, y: bounds.midY - 14, width: bounds.width - 64, height: 14)
        let stateAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]
        (stateText as NSString).draw(in: stateRect, withAttributes: stateAttr)
    }

    func configure(definition: AppDefinition, state: WatcherState, isRunning: Bool) {
        self.definition = definition
        self.appName = definition.displayName

        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: definition.bundleId
        ).first {
            self.appIcon = app.icon
        } else {
            self.appIcon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }

        if !isRunning {
            stateText = "未运行"
            dotColor = NSColor.gray.withAlphaComponent(0.3)
        } else {
            switch state {
            case .idle:
                stateText = "就绪"
                dotColor = NSColor.systemGray
            case .working:
                stateText = "正在工作…"
                dotColor = NSColor.systemGreen
            case .needsAttention:
                stateText = "等待接手"
                dotColor = NSColor.systemRed
            }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let def = definition else { return }
        onActivate?(def.bundleId)
    }
}
