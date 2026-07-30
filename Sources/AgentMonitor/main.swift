import Cocoa

// Entry point for AgentMonitor — a menu bar app that monitors AI agent
// desktop apps and notifies the user when an agent needs attention.
//
// The app runs as a background (agent) process: no Dock icon, just a status
// bar item. It polls the Accessibility trees of watched apps every few
// seconds and pops a floating notification when an agent finishes a round,
// shows a "Continue" button, requests approval, or otherwise needs the user
// to step in.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon

// Ensure accessibility permission is granted before starting the engine.
if !AXUtilities.checkAccessibilityPermission() {
    print("⚠️ 需要辅助功能权限才能监控智能体窗口。请在系统设置 > 隐私与安全 > 辅助功能中授权。")
    // We still launch — the menu bar will let the user open preferences to grant.
}

app.run()
