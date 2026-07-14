import AppKit
import SwiftUI

// MARK: - Data model matching stats.json

struct NameTokens: Decodable, Identifiable {
    let name: String
    let tokens: Int
    var id: String { name }
}

struct LimitWindow: Decodable {
    let used_percent: Double?
    let resets_at: Double?
    let window_minutes: Int?
}

struct CodexLimits: Decodable {
    let five_h: LimitWindow?
    let weekly: LimitWindow?
    let plan: String?
    let as_of: Double?
}

struct LimitsPct: Decodable {
    let five_h: Double
    let weekly: Double
    let five_h_limit: Int
    let weekly_limit: Int
}

struct Breakdown: Decodable {
    let input: Int
    let output: Int
    let cache_creation: Int
    let cache_read: Int
}

struct Provider: Decodable {
    let lifetime_total: Int
    let today_total: Int
    let w5h: Int
    let w24h: Int
    let w7d: Int
    let sessions: Int
    let live: Int
    var lifetime_breakdown: Breakdown? = nil
    var top_models: [NameTokens] = []
    var top_projects: [NameTokens] = []
    var limits: CodexLimits? = nil
    var limits_pct: LimitsPct? = nil
}

struct Combined: Decodable {
    let lifetime_total: Int
    let today_total: Int
    let w5h: Int
    let w24h: Int
    let w7d: Int
    let sessions: Int
    let live: Int
    var cache_read: Int = 0
}

struct LiveSlot: Decodable {
    let open: Int
    let running: Int
    let idle: Int
}

struct LiveSessions: Decodable {
    let claude: LiveSlot
    let codex: LiveSlot
    let open: Int
    let running: Int
    let idle: Int
    let avail: Bool
}

struct Stats: Decodable {
    let generated_at: Double
    let claude: Provider
    let codex: Provider
    let combined: Combined
    let top_projects: [NameTokens]
    var top_sessions: [NameTokens] = []
    var live_sessions: LiveSessions? = nil
}

// MARK: - Formatting helpers

func fmtTokens(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.0fK", d / 1e3) }
    return "\(n)"
}

func fmtReset(_ epoch: Double?) -> String {
    guard let e = epoch else { return "" }
    let secs = e - Date().timeIntervalSince1970
    if secs <= 0 { return "resets now" }
    let d = Int(secs) / 86400
    let h = (Int(secs) % 86400) / 3600
    let m = (Int(secs) % 3600) / 60
    if d > 0 { return "resets in \(d)d \(h)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

func fmtAgo(_ epoch: Double) -> String {
    let secs = Date().timeIntervalSince1970 - epoch
    if secs < 60 { return "just now" }
    let m = Int(secs) / 60
    if m < 60 { return "\(m)m ago" }
    let h = m / 60
    if h < 24 { return "\(h)h ago" }
    return "\(h / 24)d ago"
}

// MARK: - Colors

extension Color {
    static let claudeAccent = Color(red: 0.85, green: 0.47, blue: 0.34)   // warm terracotta
    static let codexAccent  = Color(red: 0.20, green: 0.78, blue: 0.62)   // teal
    static let liveGreen    = Color(red: 0.30, green: 0.85, blue: 0.42)
    static let dim          = Color.white.opacity(0.45)
    static let dimmer       = Color.white.opacity(0.28)
}

// MARK: - Observable model

final class OverlayModel: ObservableObject {
    @Published var stats: Stats?
    @Published var refreshing = false
    @Published var error: String?

    private var timer: Timer?

    var statsURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CCStat")
        return base.appendingPathComponent("stats.json")
    }

    var aggScriptPath: String {
        if let p = Bundle.main.path(forResource: "agg", ofType: "py") { return p }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ccstat/agg.py").path
    }

    func start() {
        load()
        refresh()   // fresh on launch
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: statsURL) else { return }
        do {
            let s = try JSONDecoder().decode(Stats.self, from: data)
            self.stats = s
            self.error = nil
        } catch {
            self.error = "parse error"
        }
    }

    func refresh() {
        if refreshing { return }
        refreshing = true
        let script = aggScriptPath
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.load()
                self.refreshing = false
            }
        }
    }
}

// MARK: - Reusable views

struct MeterBar: View {
    let fraction: Double     // 0...1
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(color)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

struct SectionLabel: View {
    let text: String
    var accent: Color = .dim
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .tracking(1.2)
            .foregroundColor(accent)
    }
}

// MARK: - Main overlay view

struct OverlayView: View {
    @EnvironmentObject var model: OverlayModel
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if let s = model.stats {
                limitsSection(s)
                Divider().overlay(Color.white.opacity(0.08))
                totalsSection(s)
                Divider().overlay(Color.white.opacity(0.08))
                whereSection(s)
                footer(s)
            } else {
                Text(model.error ?? "Loading…")
                    .font(.system(size: 11)).foregroundColor(.dim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 256, idealWidth: 296, maxWidth: 620,
               maxHeight: .infinity, alignment: .top)
        .onReceive(tick) { now = $0 }
    }

    // Header (drag handle) ------------------------------------------------
    var header: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.claudeAccent).frame(width: 7, height: 7)
            Circle().fill(Color.codexAccent).frame(width: 7, height: 7)
            Text("USAGE")
                .font(.system(size: 11, weight: .heavy)).tracking(2)
                .foregroundColor(.white.opacity(0.9))
            Spacer()
            if let s = model.stats {
                Text(fmtAgo(s.generated_at))
                    .font(.system(size: 9)).foregroundColor(.dimmer)
            }
            Button(action: { model.refresh() }) {
                Image(systemName: model.refreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                    .rotationEffect(.degrees(model.refreshing ? 360 : 0))
                    .animation(model.refreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: model.refreshing)
            }
            .buttonStyle(.plain)
            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.dim)
            }
            .buttonStyle(.plain)
        }
    }

    // Limits (Codex = real %, Claude = token volume, no local %) ----------
    @ViewBuilder
    func limitsSection(_ s: Stats) -> some View {
        HStack {
            SectionLabel(text: "Limits")
            Spacer()
            Text("% used").font(.system(size: 8)).foregroundColor(.dimmer)
        }
        // Codex — real percentages from its logs
        HStack(spacing: 6) {
            Circle().fill(Color.codexAccent).frame(width: 6, height: 6)
            Text("Codex").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            if let plan = s.codex.limits?.plan {
                Text(plan.uppercased())
                    .font(.system(size: 7.5, weight: .bold)).tracking(0.5)
                    .foregroundColor(.codexAccent)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.codexAccent.opacity(0.15)))
            }
            Spacer()
        }
        if let lim = s.codex.limits, (lim.five_h != nil || lim.weekly != nil) {
            limitRow("5h", lim.five_h)
            limitRow("Week", lim.weekly)
        } else {
            Text("no limit data cached — run Codex once")
                .font(.system(size: 9)).foregroundColor(.dimmer).padding(.leading, 12)
        }
        // Claude — % vs a configurable cap (Claude Code stores no real limit locally)
        HStack(spacing: 6) {
            Circle().fill(Color.claudeAccent).frame(width: 6, height: 6)
            Text("Claude").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            Spacer()
            Text("est · vs set cap")
                .font(.system(size: 8)).foregroundColor(.dimmer)
        }
        if let lp = s.claude.limits_pct {
            pctRow("5h", lp.five_h, .claudeAccent)
            pctRow("Week", lp.weekly, .claudeAccent)
        }
    }

    func pctRow(_ label: String, _ pct: Double, _ color: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                .frame(width: 34, alignment: .leading)
            MeterBar(fraction: pct / 100, color: pct >= 85 ? .red : color)
            Text("\(Int(pct))%").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85)).frame(width: 40, alignment: .trailing)
        }
    }

    @ViewBuilder
    func limitRow(_ label: String, _ w: LimitWindow?) -> some View {
        if let w = w, let pct = w.used_percent {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                        .frame(width: 34, alignment: .leading)
                    MeterBar(fraction: pct / 100, color: pct >= 85 ? .red : .codexAccent)
                    Text("\(Int(pct))%").font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85)).frame(width: 40, alignment: .trailing)
                }
                Text("\(Int(100 - pct))% left · \(fmtReset(w.resets_at))")
                    .font(.system(size: 8)).foregroundColor(.dimmer)
                    .padding(.leading, 34)
            }
        }
    }

    // Token windows (5h / today / 7d) both providers ---------------------
    @ViewBuilder
    func windowsSection(_ s: Stats) -> some View {
        HStack {
            SectionLabel(text: "Token flow")
            Spacer()
            Text("5h · 24h · 7d").font(.system(size: 8)).foregroundColor(.dimmer)
        }
        providerWindows("Claude", .claudeAccent, s.claude)
        providerWindows("Codex", .codexAccent, s.codex)
    }

    func providerWindows(_ name: String, _ c: Color, _ p: Provider) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(c).frame(width: 6, height: 6)
                Text(name).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.8))
            }.frame(width: 66, alignment: .leading)
            Spacer()
            miniStat(fmtTokens(p.w5h))
            miniStat(fmtTokens(p.w24h))
            miniStat(fmtTokens(p.w7d))
        }
    }

    func miniStat(_ v: String) -> some View {
        Text(v).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.82))
            .frame(width: 46, alignment: .trailing)
    }

    // Combined + split totals --------------------------------------------
    @ViewBuilder
    func totalsSection(_ s: Stats) -> some View {
        HStack(spacing: 10) {
            bigTotal("TODAY", s.combined.today_total, .white)
            bigTotal("WEEK", s.combined.w7d, .white.opacity(0.9))
            bigTotal("LIFETIME", s.combined.lifetime_total, .white.opacity(0.8))
        }
        HStack(spacing: 6) {
            splitPill("Claude", .claudeAccent, s.claude.today_total)
            splitPill("Codex", .codexAccent, s.codex.today_total)
            Spacer()
            Text("incl. \(fmtTokens(s.combined.cache_read)) cache")
                .font(.system(size: 8)).foregroundColor(.dimmer)
        }
    }

    func bigTotal(_ label: String, _ v: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8, weight: .heavy)).tracking(0.8).foregroundColor(.dim)
            Text(fmtTokens(v)).font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(color).minimumScaleFactor(0.6).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func splitPill(_ name: String, _ c: Color, _ v: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(name).font(.system(size: 9)).foregroundColor(.dim)
            Text(fmtTokens(v)).font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }

    // Where tokens go + sessions -----------------------------------------
    @ViewBuilder
    func whereSection(_ s: Stats) -> some View {
        HStack {
            SectionLabel(text: "Named sessions")
            Spacer()
            Text("--resume name · Claude").font(.system(size: 8)).foregroundColor(.dimmer)
        }
        let top = s.top_sessions.prefix(4)
        if top.isEmpty {
            Text("no named sessions yet")
                .font(.system(size: 9)).foregroundColor(.dimmer)
        }
        let maxTok = max(1, top.first?.tokens ?? 1)
        ForEach(Array(top)) { sess in
            HStack(spacing: 8) {
                Text(sess.name).font(.system(size: 10)).foregroundColor(.white.opacity(0.75))
                    .frame(width: 108, alignment: .leading).lineLimit(1).truncationMode(.middle)
                MeterBar(fraction: Double(sess.tokens) / Double(maxTok), color: .white.opacity(0.35), height: 4)
                Text(fmtTokens(sess.tokens)).font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.dim).frame(width: 46, alignment: .trailing)
            }
        }
    }

    func footer(_ s: Stats) -> some View {
        let ls = s.live_sessions
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill((ls?.running ?? 0) > 0 ? Color.liveGreen : Color.dimmer)
                        .frame(width: 6, height: 6)
                    Text("\(ls?.running ?? 0) running").font(.system(size: 10, weight: .semibold))
                        .foregroundColor((ls?.running ?? 0) > 0 ? .liveGreen : .dim)
                }
                HStack(spacing: 4) {
                    Circle().strokeBorder(Color.dim, lineWidth: 1).frame(width: 6, height: 6)
                    Text("\(ls?.idle ?? 0) idle").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.dim)
                }
                Spacer()
                Text("\(ls?.open ?? 0) open").font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
            }
            HStack {
                Text("Claude \(ls?.claude.open ?? 0) · Codex \(ls?.codex.open ?? 0) open")
                    .font(.system(size: 9)).foregroundColor(.dimmer)
                Spacer()
                Text("\(s.combined.sessions) all-time")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.dimmer)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Blur-backed rounded container hosting the SwiftUI view

final class BlurHostView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        window?.invalidateShadow()   // recompute shadow to match rounded shape (no square box)
    }
    // let the whole background drag the window
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - Visible resize grip (bottom-right), keeps top-left anchored

final class ResizeGrip: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: NSCursor.crosshair)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let mouse = NSEvent.mouseLocation                  // screen coords
        var f = win.frame
        let topY = f.origin.y + f.size.height              // fixed top edge
        let leftX = f.origin.x                             // fixed left edge
        var w = mouse.x - leftX
        var h = topY - mouse.y
        w = max(win.minSize.width, min(win.maxSize.width, w))
        h = max(win.minSize.height, min(win.maxSize.height, h))
        f.size.width = w
        f.size.height = h
        f.origin.y = topY - h
        win.setFrame(f, display: true)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.30).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1.2
        for off in [5.0, 9.0, 13.0] {
            p.move(to: NSPoint(x: bounds.maxX - off, y: 3))
            p.line(to: NSPoint(x: bounds.maxX - 3, y: off))
        }
        p.stroke()
    }
}

// NSHostingView that receives the first click even when the panel isn't key
// (so the refresh/close buttons work in a non-activating floating panel).
final class ClickThroughHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    let model = OverlayModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no dock icon, menu-bar-agent style

        let hosting = ClickThroughHostingView(
            rootView: AnyView(OverlayView().environmentObject(model)))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let blur = BlurHostView()
        blur.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: blur.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        let size = hosting.fittingSize
        let rect = NSRect(x: 0, y: 0, width: max(size.width, 296), height: max(size.height, 260))
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel, .resizable],
                        backing: .buffered, defer: false)
        panel.contentView = blur
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false    // window shadow is square around the rounded card — drop it for clean edges
        panel.level = .statusBar   // above ordinary app windows (e.g. Slack), stays at the forefront
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.minSize = NSSize(width: 256, height: 240)
        panel.maxSize = NSSize(width: 620, height: 1000)

        // restore saved position or default to top-right
        panel.setFrameAutosaveName("CCStatOverlayPanel")
        if panel.frame.origin == .zero {
            if let screen = NSScreen.main {
                let vf = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: vf.maxX - rect.width - 24, y: vf.maxY - rect.height - 24))
            }
        }
        // visible resize grip pinned to bottom-right
        let grip = ResizeGrip(frame: NSRect(x: rect.width - 18, y: 0, width: 18, height: 18))
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        blur.addSubview(grip)

        panel.orderFrontRegardless()
        panel.invalidateShadow()
        model.start()
        // keep it at the forefront even if another app raises a high-level window
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.panel.orderFrontRegardless()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
