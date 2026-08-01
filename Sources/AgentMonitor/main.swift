import Cocoa

// Entry point for AgentMonitor — a menu bar app that monitors AI agent
// desktop apps and notifies the user when an agent needs attention.
//
// The app runs as a background (accessory) process: no Dock icon, just a
// status bar item. It polls the Accessibility trees of watched apps every
// few seconds and pops a floating notification when an agent finishes a
// round, shows a "Continue" button, requests approval, or otherwise needs
// the user to step in.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
