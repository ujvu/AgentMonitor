// Standalone engine test: verifies the v13 timer driver behaves correctly
// without needing the full app (which is currently blocked by a keychain
// decrypt hang in securityd).
//   swiftc -o enginetest enginetest.swift IslandAnimationEngine.swift Logger.swift \
//          -framework Cocoa && ./enginetest
import Foundation
import Cocoa

func makeEngine() -> (IslandAnimationEngine,
                      () -> [(Double, IslandMorphState)],
                      () -> [IslandPhase]) {
    let engine = IslandAnimationEngine()
    var applied: [(Double, IslandMorphState)] = []
    var completed: [IslandPhase] = []
    engine.onApply = { applied.append((Date().timeIntervalSinceReferenceDate, $0)) }
    engine.onComplete = { completed.append($0) }
    return (engine, { applied }, { completed })
}

func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

@main
struct EngineTestMain {
    static func main() { runTests() }
}

func runTests() {

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print("  \(cond ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " — " + detail)")
    if !cond { failures += 1 }
}

// ── T1: quick-collapse sequence completes in real wall time ──
print("── T1: 快速收起序列按真实墙钟完成 ──")
let (e1, a1, c1) = makeEngine()
let t0 = Date()
e1.morphSequence([
    IslandMorphStep(target: IslandMorphTarget(size: NSSize(width: 244, height: 60), cornerRadius: 30, contentAlpha: 0),
                    phase: .contentFadeOut, duration: 0.05),
    IslandMorphStep(target: IslandMorphTarget(size: NSSize(width: 100, height: 4), cornerRadius: 2),
                    phase: .collapsing, duration: 0.12),
    IslandMorphStep(target: IslandMorphTarget(size: NSSize(width: 100, height: 4), cornerRadius: 2),
                    phase: .dormant, duration: 0.04)
])
while c1().count < 3 && Date().timeIntervalSince(t0) < 3.0 { spin(0.01) }
let wall = Date().timeIntervalSince(t0)
let phases = c1()
let lastState = a1().last?.1
check("总耗时 0.15s~0.6s（真实墙钟，非慢放）", wall >= 0.15 && wall <= 0.6,
      String(format: "实测 %.2fs", wall))
check("段完成回调按序补发", phases == [.contentFadeOut, .collapsing, .dormant],
      "\(phases)")
check("终态几何 = 100×4", lastState?.size == NSSize(width: 100, height: 4),
      "\(lastState?.size ?? .zero)")
check("应用帧数受合并限制（不洪泛）", a1().count < 200, "\(a1().count) frames")

// ── T2: interruption — new morph cancels the old sequence's completions ──
print("── T2: 中断 — 新序列作废旧序列 ──")
let (e2, a2, c2) = makeEngine()
let t2 = Date()
e2.morphSequence([
    IslandMorphStep(target: IslandMorphTarget(size: NSSize(width: 300, height: 80), cornerRadius: 40),
                    phase: .awakening, duration: 0.05),
    IslandMorphStep(target: IslandMorphTarget(size: NSSize(width: 260, height: 64), cornerRadius: 32),
                    phase: .awakening, duration: 0.1)
])
usleep(30_000)   // 30ms into the first sequence
e2.morphSequence([
    IslandMorphStep(target: IslandMorphTarget(size: NSSize(width: 100, height: 4), cornerRadius: 2),
                    phase: .collapsing, duration: 0.05)
])
while c2().count < 1 && Date().timeIntervalSince(t2) < 3.0 { spin(0.01) }
let phases2 = c2()
let last2 = a2().last?.1
check("只有新序列的完成回调（旧的 .awakening 不补发）", phases2 == [.collapsing], "\(phases2)")
check("终态 = 新序列目标 100×4", last2?.size == NSSize(width: 100, height: 4),
      "\(last2?.size ?? .zero)")

// ── T3: expand sequence completes to full size in real time ──
print("── T3: 展开序列按真实墙钟完成 ──")
let (e3, a3, c3) = makeEngine()
let t3 = Date()
e3.morphSequence([
    IslandMorphStep(target: IslandMorphTarget(size: NSSize(width: 100, height: 20), cornerRadius: 10),
                    phase: .awakening, duration: 0.15),
    IslandMorphStep(target: IslandMorphTarget(size: NSSize(width: 260, height: 64), cornerRadius: 32),
                    phase: .awakening, duration: 0.3),
    IslandMorphStep(target: IslandMorphTarget(size: NSSize(width: 260, height: 64), cornerRadius: 32, contentAlpha: 1),
                    phase: .contentFadeIn, duration: 0.15)
])
while c3().count < 3 && Date().timeIntervalSince(t3) < 3.0 { spin(0.01) }
let wall3 = Date().timeIntervalSince(t3)
let last3 = a3().last?.1
check("总耗时 0.4s~1.0s", wall3 >= 0.4 && wall3 <= 1.0, String(format: "实测 %.2fs", wall3))
check("终态 = 260×64 + 内容淡入", last3?.size == NSSize(width: 260, height: 64) && last3?.contentAlpha == 1,
      "\(last3?.size ?? .zero) alpha=\(last3?.contentAlpha ?? -1)")

// ── T4: cancel() drops everything without completions ──
print("── T4: cancel() 不触发完成回调 ──")
let (e4, _, c4) = makeEngine()
e4.morphSequence([
    IslandMorphStep(target: IslandMorphTarget(size: NSSize(width: 260, height: 64), cornerRadius: 32),
                    phase: .awakening, duration: 0.1)
])
usleep(20_000)
e4.cancel()
spin(0.5)
check("cancel 后无完成回调", c4().isEmpty, "\(c4())")

print(failures == 0 ? "\n════ 引擎测试全部通过 ════" : "\n════ \(failures) 项失败 ════")
exit(failures == 0 ? 0 : 1)
}
