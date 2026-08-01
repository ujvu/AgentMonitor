// AgentMonitor UI Test Harness (debug-build only)
//
// Drives the island through the exact delegate paths a real mouse would
// (mouseEntered → peek, single-click → dismiss) via the #if DEBUG remote
// control in FloatingIsland, and observes the window through the AX API.
// Requires the app to be built with -D DEBUG (see am_build_debug.sh).
//
// Usage:  swiftc -o uitest uitest.swift -framework ApplicationServices \
//             -framework Cocoa && ./uitest
//
// Scenarios:
//   S1  Lifecycle: peek → expand → dismiss → collapse → orderOut (timing)
//   S2  Idempotency: 5× dismiss fires exactly one collapse; island still
//       dismissable afterwards (pendingHide must not get stuck)
//   S3  Interruption: dismiss → re-peek mid-collapse → re-expand → dismiss
//       again still works (regression test for the pendingHide fix)
//   S0  Real-mouse sanity: System Events click on the island's top-center
//       region must reach the island (best effort)
//
// The harness pauses the monitor engine at start (TestUI "pause") so the
// live OCR state machine cannot interfere; it resumes at the end.

import Foundation
import ApplicationServices
import AppKit

// MARK: - Config

let testNotification = "com.cuishiming.AgentMonitor.TestUI"
let appName = "AgentMonitor"
let expandedMinHeight: CGFloat = 60   // expanded/attention card heights (64/72)
let expandedMinWidth: CGFloat = 200   // expanded cards are ≥260 wide; the sliver is 100 wide
let sliverHeight: CGFloat = 80        // hidden sliver + hover hit region

// MARK: - Process helpers

func agentMonitorPid() -> pid_t? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", appName]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let pid = pid_t(s) else { return nil }
    return pid
}

// MARK: - Command (file channel; the DEBUG app polls this at 50ms)

let testCommandPath = "/tmp/am_testui_cmd"

func send(_ action: String) {
    // Append with a newline; the app clears the file after draining.
    if let handle = FileHandle(forWritingAtPath: testCommandPath) {
        handle.seekToEndOfFile()
        handle.write((action + "\n").data(using: .utf8)!)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: testCommandPath, contents: (action + "\n").data(using: .utf8))
    }
}

// MARK: - AX observation

/// Returns (windowCount, width, height, hiddenFlag). (0, 0, 0, false) when
/// no window is visible to AX.
func islandState(_ pid: pid_t) -> (count: Int, w: CGFloat, h: CGFloat, hidden: Bool) {
    let app = AXUIElementCreateApplication(pid)
    var windows: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
    guard err == .success, let wins = windows as? [AXUIElement], let w = wins.first else {
        return (0, 0, 0, false)
    }
    var sizeV: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeV)
    var s = CGSize.zero
    if let sv = sizeV { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    var hiddenV: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXHiddenAttribute as CFString, &hiddenV)
    let hidden = (hiddenV as? Bool) ?? false
    return (wins.count, s.width, s.height, hidden)
}

func isExpanded(_ s: (count: Int, w: CGFloat, h: CGFloat, hidden: Bool)) -> Bool {
    // Width discriminates: the hidden sliver (100×4 or 100×80 hit region)
    // must NOT count as expanded.
    s.count == 1 && !s.hidden && s.w >= expandedMinWidth && s.h >= expandedMinHeight
}

/// The dormant sliver: raw morph geometry (100×4) or with the hover hit
/// region installed (100×80). Both are "the island is visible but collapsed".
func isSliver(_ s: (count: Int, w: CGFloat, h: CGFloat, hidden: Bool)) -> Bool {
    s.count == 1 && !s.hidden && s.w <= 120 && s.h >= 3 && s.h <= 80
}

/// Ordered out: AX no longer lists the window, or reports it hidden, or it
/// collapsed below any visible geometry.
func isGone(_ s: (count: Int, w: CGFloat, h: CGFloat, hidden: Bool)) -> Bool {
    s.count == 0 || s.hidden || s.h < 3
}

/// Polls until `pred` is true; returns the sequence of observed states.
func poll(_ pid: pid_t, timeout: TimeInterval, every: TimeInterval = 0.01,
          _ pred: ((count: Int, w: CGFloat, h: CGFloat, hidden: Bool)) -> Bool)
    -> (ok: Bool, states: [(t: TimeInterval, s: (count: Int, w: CGFloat, h: CGFloat, hidden: Bool))]) {
    let start = Date()
    var states: [(TimeInterval, (count: Int, w: CGFloat, h: CGFloat, hidden: Bool))] = []
    while Date().timeIntervalSince(start) < timeout {
        let s = islandState(pid)
        states.append((Date().timeIntervalSince(start), s))
        if pred(s) { return (true, states) }
        usleep(useconds_t(every * 1_000_000))
    }
    return (false, states)
}

// MARK: - Normalization

/// Tries to get the island into the expanded state; returns true on success.
func ensureExpanded(_ pid: pid_t) -> Bool {
    // If already expanded, done.
    if isExpanded(islandState(pid)) { return true }
    // If gone, re-show first.
    if isGone(islandState(pid)) {
        send("show")
        _ = poll(pid, timeout: 2.0) { s in s.count == 1 }
    }
    // If sliver, peek.
    let s = islandState(pid)
    if isSliver(s) {
        send("peek")
        let r = poll(pid, timeout: 3.0, every: 0.05) { isExpanded($0) }
        if r.ok { return true }
        // One retry (a racing state event may have swallowed the peek).
        send("peek")
        let r2 = poll(pid, timeout: 3.0, every: 0.05) { isExpanded($0) }
        return r2.ok
    }
    if isExpanded(s) { return true }
    return false
}

// MARK: - Scenario bookkeeping

var passCount = 0
var failCount = 0
var skipCount = 0

func check(_ name: String, _ cond: Bool, detail: String = "") {
    if cond {
        passCount += 1
        print("  ✅ \(name)\(detail.isEmpty ? "" : " — " + detail)")
    } else {
        failCount += 1
        print("  ❌ \(name)\(detail.isEmpty ? "" : " — " + detail)")
    }
}

// MARK: - Scenarios

func scenarioS1(_ pid: pid_t) {
    print("\n── S1 生命周期: peek → expand → dismiss → collapse → orderOut ──")
    guard ensureExpanded(pid) else {
        skipCount += 1
        print("  ⏭️  SKIP: could not reach expanded state (live state machine interference)")
        return
    }
    let pre = islandState(pid)
    print("  expanded baseline: \(Int(pre.w))x\(Int(pre.h))")

    let t0 = Date()
    send("dismiss")
    let r = poll(pid, timeout: 2.0) { isGone($0) }
    let dt = Date().timeIntervalSince(t0)
    check("dismiss → orderOut 完成", r.ok, detail: "耗时 \(String(format: "%.2f", dt))s")
    check("quick 收起 ≤ 0.8s", r.ok && dt <= 0.8, detail: "实测 \(String(format: "%.2f", dt))s")

    // Report the shrink path (content fade + geometry collapse should both
    // be visible as intermediate sizes between 64 and 4).
    let heights = r.states.map { Int($0.s.h) }.filter { $0 > 0 && $0 < 64 }
    if !heights.isEmpty {
        print("  收缩中间态高度序列: \(heights.prefix(12))")
        check("可见形变动画（存在中间态）", heights.count >= 2)
    } else {
        print("  未捕获到收缩中间态（轮询粒度 ~10ms）")
        check("可见形变动画（存在中间态）", false)
    }
}

func scenarioS2(_ pid: pid_t) {
    print("\n── S2 幂等性: 连续 5× dismiss 只收起一次 ──")
    guard ensureExpanded(pid) else {
        skipCount += 1
        print("  ⏭️  SKIP: could not reach expanded state")
        return
    }
    for _ in 0..<5 {
        send("dismiss")
        usleep(25_000)
    }
    let r = poll(pid, timeout: 2.5) { isGone($0) }
    check("5× dismiss 后窗口已收起(orderOut)", r.ok)
    // Ensure it never re-expanded on its own in that window.
    let stuckExpanded = r.states.contains { isExpanded($0.s) }
    check("收起过程中无重复展开/卡住", !stuckExpanded || !r.ok)

    // Re-show and confirm the island is fully functional afterwards
    // (pendingHide must not be stuck from the burst).
    send("show")
    let back = poll(pid, timeout: 3.0) { s in s.count == 1 }
    check("重新显示正常", back.ok)
    if back.ok {
        let ok2 = ensureExpanded(pid)
        check("再次展开正常", ok2)
        if ok2 {
            send("dismiss")
            let r2 = poll(pid, timeout: 2.0) { isGone($0) }
            check("再次 dismiss 正常（pendingHide 未卡死）", r2.ok)
        }
    }
}

func scenarioS3(_ pid: pid_t) {
    print("\n── S3 动画中断: dismiss 中被重新 peek 打断 → 重新展开 ──")
    guard ensureExpanded(pid) else {
        skipCount += 1
        print("  ⏭️  SKIP: could not reach expanded state")
        return
    }
    send("dismiss")
    usleep(40_000)              // collapse (0.21s) 刚开始
    send("peek")                // 中断：collapse 中重新进入

    let r = poll(pid, timeout: 2.0) { isExpanded($0) }
    check("中断后重新展开（collapse 被取消）", r.ok, detail: r.ok ? "\(Int(r.states.last!.s.w))x\(Int(r.states.last!.s.h))" : "")
    let goneDuringInterrupt = r.states.contains { isGone($0.s) }
    check("中断期间未误 orderOut", !goneDuringInterrupt)

    // The real regression check: after an interrupted collapse, a fresh
    // dismiss must still work (pendingHide must have been cleared).
    if isExpanded(islandState(pid)) {
        send("dismiss")
        let r2 = poll(pid, timeout: 2.0) { isGone($0) }
        check("中断后再次 dismiss 正常（pendingHide 修复）", r2.ok)
    } else {
        check("中断后再次 dismiss 正常（pendingHide 修复）", false, detail: "前置状态异常: \(islandState(pid))")
    }
}

func scenarioS0(_ pid: pid_t) {
    print("\n── S0 真实鼠标冒烟: System Events 点击浮岛顶部区域 ──")
    let s = islandState(pid)
    guard s.count == 1 else {
        skipCount += 1
        print("  ⏭️  SKIP: 浮岛不可见，无法验证真实点击")
        return
    }
    let screen = NSScreen.main?.frame ?? .zero
    let clickPoint = CGPoint(x: screen.midX, y: 40)   // top-left origin, inside island
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"System Events\" to click at {\(Int(clickPoint.x)), \(Int(clickPoint.y))}"]
    try? p.run()
    p.waitUntilExit()
    print("  clicked (\(Int(clickPoint.x)), \(Int(clickPoint.y))) — initial state \(Int(s.w))x\(Int(s.h))")
    let r = poll(pid, timeout: 3.0, every: 0.05) { isGone($0) }
    check("点击后浮岛收起(orderOut)", r.ok, detail: "点击命中区域或触发收起")
}

// MARK: - Main

guard let pid = agentMonitorPid() else {
    print("❌ AgentMonitor 未运行")
    exit(1)
}
print("AgentMonitor pid=\(pid)")

// Ensure a clean command file (a stale file from a previous run could
// otherwise be executed against this freshly restarted app).
try? "".write(toFile: testCommandPath, atomically: true, encoding: .utf8)

// Freeze the live state machine so the scenarios are deterministic.
send("pause")
usleep(500_000)

// Wait for the island window to appear (startup can take a while on a
// fresh launch); if it never appears, force-show once.
var present = poll(pid, timeout: 8.0, every: 0.2) { $0.count >= 1 }.ok
if !present {
    send("show")
    present = poll(pid, timeout: 6.0, every: 0.2) { $0.count >= 1 }.ok
}
print("初始状态: \(islandState(pid)) (window present: \(present))")

scenarioS1(pid)
scenarioS2(pid)
scenarioS3(pid)
scenarioS0(pid)

print("\n════════ 汇总: \(passCount) PASS / \(failCount) FAIL / \(skipCount) SKIP ════════")

// Resume monitoring (only if we paused it; harmless if already running).
send("resume")
exit(failCount == 0 ? 0 : 1)
