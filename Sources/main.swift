import AppKit
import SwiftUI

// MARK: - Data model matching stats.json

struct NameTokens: Decodable, Identifiable {
    let name: String
    let tokens: Int
    var id: String { name }
}

struct NamedSession: Decodable, Identifiable {
    let name: String
    let tokens: Int
    var tokens_nc: Int = 0
    let last_activity: Double
    let running: Bool
    var live: Bool = false
    var id: String { name }
}

enum SessView { case usage, current, recent }

struct MemSample {
    let v: Double     // pressure %
    let level: Int    // 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level)
}

struct Memory: Decodable {
    let physical: Double
    let used: Double
    let cached: Double
    let swap: Double
    let app: Double
    let wired: Double
    let compressed: Double
    let pressure_pct: Double
    let level: String
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

struct RealLimits: Decodable {
    let five_h: LimitWindow?
    let weekly: LimitWindow?
    var fable: LimitWindow? = nil
    let ok: Bool
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
    var today_nc: Int = 0
    var lifetime_breakdown: Breakdown? = nil
    var top_models: [NameTokens] = []
    var top_projects: [NameTokens] = []
    var limits: CodexLimits? = nil
    var limits_pct: LimitsPct? = nil
    var real_limits: RealLimits? = nil
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
    var lifetime_nc: Int = 0
    var today_nc: Int = 0
    var w7d_nc: Int = 0
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
    var named_sessions: [NamedSession] = []
    var live_sessions: LiveSessions? = nil
    var memory: Memory? = nil
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
    @Published var memHistory: [MemSample] = []
    @Published var horizontal: Bool = UserDefaults.standard.bool(forKey: "ccstat.horizontal")
    @Published var showCache: Bool = (UserDefaults.standard.object(forKey: "ccstat.showCache") as? Bool) ?? true
    var onLayout: (() -> Void)?

    func toggleLayout() {
        horizontal.toggle()
        UserDefaults.standard.set(horizontal, forKey: "ccstat.horizontal")
        onLayout?()
    }

    func toggleCache() {
        showCache.toggle()
        UserDefaults.standard.set(showCache, forKey: "ccstat.showCache")
    }

    private var timer: Timer?
    private var memTimer: Timer?

    // Native, cheap memory-pressure read (Mach) for a high-fidelity graph,
    // sampled far more often than the 60s token refresh.
    func currentPressurePct() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pageSize = Double(vm_kernel_page_size)
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        guard physical > 0 else { return nil }
        return 100.0 * (wired + compressed) / physical
    }

    func currentPressureLevel() -> Int {
        var lvl: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &size, nil, 0)
        return Int(lvl)
    }

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
        // high-fidelity memory-pressure sampling (every 2s)
        memTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.currentPressurePct() else { return }
            self.memHistory.append(MemSample(v: p, level: self.currentPressureLevel()))
            if self.memHistory.count > 150 { self.memHistory.removeFirst(self.memHistory.count - 150) }
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

func pressureLevelColor(_ level: Int) -> Color {
    switch level {
    case 4: return Color(red: 0.92, green: 0.30, blue: 0.28)   // critical
    case 2: return Color(red: 0.95, green: 0.77, blue: 0.22)   // warning
    default: return .liveGreen                                  // normal
    }
}

struct MemSparkline: View {
    let history: [MemSample]

    var body: some View {
        GeometryReader { geo in
            content(Array(history.suffix(150)), geo.size)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)))
    }

    @ViewBuilder
    func content(_ pts: [MemSample], _ size: CGSize) -> some View {
        if pts.count > 1 {
            ZStack {
                // one filled area per level so historical bands keep their color
                ForEach([1, 2, 4], id: \.self) { lvl in
                    areaFor(pts, lvl, size).fill(pressureLevelColor(lvl).opacity(0.45))
                }
            }
        } else {
            Text("collecting…").font(.system(size: 8)).foregroundColor(.dimmer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func xPos(_ i: Int, _ n: Int, _ w: CGFloat) -> CGFloat { CGFloat(i) / CGFloat(max(1, n)) * w }
    private func yPos(_ v: Double, _ h: CGFloat) -> CGFloat { h - CGFloat(min(1.0, max(0, v / 100.0))) * (h - 2) - 1 }

    private func areaFor(_ pts: [MemSample], _ lvl: Int, _ size: CGSize) -> Path {
        var p = Path()
        let n = pts.count - 1
        for i in 0..<n where pts[i].level == lvl {
            let x0 = xPos(i, n, size.width), x1 = xPos(i + 1, n, size.width)
            p.move(to: CGPoint(x: x0, y: size.height))
            p.addLine(to: CGPoint(x: x0, y: yPos(pts[i].v, size.height)))
            p.addLine(to: CGPoint(x: x1, y: yPos(pts[i + 1].v, size.height)))
            p.addLine(to: CGPoint(x: x1, y: size.height))
            p.closeSubpath()
        }
        return p
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
    @State private var sessView: SessView = .usage
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if let s = model.stats {
                if model.horizontal { horizontalContent(s) } else { verticalContent(s) }
            } else {
                Text(model.error ?? "Loading…")
                    .font(.system(size: 11)).foregroundColor(.dim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: model.horizontal ? 640 : 256,
               idealWidth: model.horizontal ? 840 : 296,
               maxWidth: model.horizontal ? 1040 : 620,
               maxHeight: .infinity, alignment: .top)
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    func verticalContent(_ s: Stats) -> some View {
        limitsSection(s)
        Divider().overlay(Color.white.opacity(0.08))
        totalsSection(s)
        Divider().overlay(Color.white.opacity(0.08))
        whereSection(s)
        footer(s)
        if let m = s.memory {
            Divider().overlay(Color.white.opacity(0.08))
            memorySection(m)
        }
    }

    @ViewBuilder
    func horizontalContent(_ s: Stats) -> some View {
        HStack(alignment: .top, spacing: 11) {
            limitsColumns(s)
            vDivider
            VStack(alignment: .leading, spacing: 6) { totalsCompact(s) }.frame(width: 132)
            vDivider
            VStack(alignment: .leading, spacing: 6) {
                whereSection(s)
                footer(s)
            }.frame(width: 190)
            if let m = s.memory {
                vDivider
                VStack(alignment: .leading, spacing: 6) { memorySection(m) }.frame(width: 206)
            }
        }
    }

    var vDivider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
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
            Button(action: { model.toggleCache() }) {
                Text("cache").font(.system(size: 8, weight: .bold))
                    .foregroundColor(model.showCache ? .white : .dim)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(
                        Capsule().fill(model.showCache ? Color.white.opacity(0.18) : Color.clear)
                            .overlay(Capsule().stroke(Color.white.opacity(0.18),
                                                      lineWidth: model.showCache ? 0 : 1)))
            }
            .buttonStyle(.plain)
            .help("Include cache tokens in counts")
            Button(action: { model.toggleLayout() }) {
                Image(systemName: model.horizontal ? "rectangle.split.1x2" : "rectangle.split.3x1")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help("Toggle wide / tall layout")
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
        Group {
            HStack {
                SectionLabel(text: "Limits")
                Spacer()
                Text("% used").font(.system(size: 8)).foregroundColor(.dimmer)
            }
            codexLimits(s)
            claudeLimits(s)
        }
    }

    // horizontal view: Codex and Claude limits as two side-by-side boxes
    @ViewBuilder
    func limitsColumns(_ s: Stats) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Codex")
                codexLimits(s)
            }.frame(width: 150)
            vDivider
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Claude")
                claudeLimits(s)
            }.frame(width: 150)
        }
    }

    @ViewBuilder
    func codexLimits(_ s: Stats) -> some View {
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
    }

    @ViewBuilder
    func claudeLimits(_ s: Stats) -> some View {
        let real = s.claude.real_limits
        let live = real?.ok == true
        HStack(spacing: 6) {
            Circle().fill(Color.claudeAccent).frame(width: 6, height: 6)
            Text("Claude").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            Spacer()
            Text(live ? "live · /usage" : "est · vs set cap")
                .font(.system(size: 8)).foregroundColor(live ? .claudeAccent : .dimmer)
        }
        if live, let r = real {
            limitRow("5h", r.five_h, .claudeAccent)
            limitRow("Week", r.weekly, .claudeAccent)
            limitRow("Fable", r.fable, .claudeAccent)
        } else if let lp = s.claude.limits_pct {
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
    func limitRow(_ label: String, _ w: LimitWindow?, _ accent: Color = .codexAccent) -> some View {
        if let w = w, let pct = w.used_percent {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                        .frame(width: 34, alignment: .leading)
                    MeterBar(fraction: pct / 100, color: pct >= 85 ? .red : accent)
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

    // pick the cache-inclusive or non-cache value based on the toggle
    func tok(_ withCache: Int, _ noCache: Int) -> Int { model.showCache ? withCache : noCache }

    var cacheNote: String { model.showCache
        ? "incl \(fmtTokens(model.stats?.combined.cache_read ?? 0)) cache"
        : "cache excluded" }

    // Combined + split totals --------------------------------------------
    @ViewBuilder
    func totalsSection(_ s: Stats) -> some View {
        HStack(spacing: 10) {
            bigTotal("TODAY", tok(s.combined.today_total, s.combined.today_nc), .white)
            bigTotal("WEEK", tok(s.combined.w7d, s.combined.w7d_nc), .white.opacity(0.9))
            bigTotal("LIFETIME", tok(s.combined.lifetime_total, s.combined.lifetime_nc), .white.opacity(0.8))
        }
        HStack(spacing: 6) {
            splitPill("Claude", .claudeAccent, tok(s.claude.today_total, s.claude.today_nc))
            splitPill("Codex", .codexAccent, tok(s.codex.today_total, s.codex.today_nc))
            Spacer()
            Text(cacheNote).font(.system(size: 8)).foregroundColor(.dimmer)
        }
    }

    @ViewBuilder
    func totalsCompact(_ s: Stats) -> some View {
        SectionLabel(text: "Tokens")
        compactTotal("TODAY", tok(s.combined.today_total, s.combined.today_nc))
        compactTotal("WEEK", tok(s.combined.w7d, s.combined.w7d_nc))
        compactTotal("LIFE", tok(s.combined.lifetime_total, s.combined.lifetime_nc))
        HStack(spacing: 5) {
            Circle().fill(Color.claudeAccent).frame(width: 5, height: 5)
            Text(fmtTokens(tok(s.claude.today_total, s.claude.today_nc))).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.7))
            Circle().fill(Color.codexAccent).frame(width: 5, height: 5)
            Text(fmtTokens(tok(s.codex.today_total, s.codex.today_nc))).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.7))
        }
        Text(cacheNote).font(.system(size: 8)).foregroundColor(.dimmer)
    }

    func compactTotal(_ label: String, _ v: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8, weight: .heavy)).tracking(0.5).foregroundColor(.dim)
                .frame(width: 44, alignment: .leading)
            Text(fmtTokens(v)).font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white).minimumScaleFactor(0.7).lineLimit(1)
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
        HStack(spacing: 4) {
            SectionLabel(text: "Sessions")
            Spacer()
            segBtn("Usage", .usage)
            segBtn("Live", .current)
            segBtn("Recent", .recent)
        }
        let list = sortedSessions(s.named_sessions)
        if list.isEmpty {
            Text(sessView == .current ? "none running" : "no named sessions yet")
                .font(.system(size: 9)).foregroundColor(.dimmer)
        }
        let maxTok = max(1, list.map { tok($0.tokens, $0.tokens_nc) }.max() ?? 1)
        ForEach(list.prefix(model.horizontal ? 3 : 4)) { sess in
            let sTok = tok(sess.tokens, sess.tokens_nc)
            HStack(spacing: 7) {
                Circle().fill(sess.running ? Color.liveGreen : (sess.live ? Color.dim : Color.clear))
                    .frame(width: 5, height: 5)
                Text(sess.name).font(.system(size: 10)).foregroundColor(.white.opacity(0.78))
                    .frame(width: 104, alignment: .leading).lineLimit(1).truncationMode(.middle)
                MeterBar(fraction: Double(sTok) / Double(maxTok), color: .white.opacity(0.35), height: 4)
                Text(sessView == .usage ? fmtTokens(sTok) : agoShort(sess.last_activity))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.dim).frame(width: 44, alignment: .trailing)
            }
        }
    }

    func segBtn(_ title: String, _ v: SessView) -> some View {
        Button(action: { sessView = v }) {
            Text(title).font(.system(size: 8, weight: .bold))
                .foregroundColor(sessView == v ? .white : .dimmer)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(sessView == v ? Color.white.opacity(0.16) : Color.clear))
        }.buttonStyle(.plain)
    }

    func sortedSessions(_ arr: [NamedSession]) -> [NamedSession] {
        switch sessView {
        case .usage:   return arr.sorted { $0.tokens > $1.tokens }
        case .current: return arr.filter { $0.live }.sorted { $0.last_activity > $1.last_activity }
        case .recent:  return arr.sorted { $0.last_activity > $1.last_activity }
        }
    }

    func agoShort(_ epoch: Double) -> String {
        let s = Date().timeIntervalSince1970 - epoch
        if s < 90 { return "now" }
        let m = Int(s) / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }

    // Memory (Activity Monitor-style) --------------------------------------
    func pressureColor(_ level: String) -> Color {
        switch level {
        case "warning": return Color(red: 0.95, green: 0.77, blue: 0.22)
        case "critical": return Color(red: 0.92, green: 0.30, blue: 0.28)
        default: return .liveGreen
        }
    }

    func fmtGB(_ bytes: Double) -> String {
        String(format: "%.2f GB", bytes / 1073741824)
    }

    @ViewBuilder
    func memorySection(_ m: Memory) -> some View {
        let lvl = model.memHistory.last?.level ?? 1
        HStack {
            SectionLabel(text: "Memory pressure")
            Spacer()
            Text(lvl == 4 ? "CRITICAL" : lvl == 2 ? "WARNING" : "NORMAL")
                .font(.system(size: 8, weight: .bold)).tracking(0.5)
                .foregroundColor(pressureLevelColor(lvl))
        }
        MemSparkline(history: model.memHistory)
            .frame(height: 26)
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 2) {
                memRow("Physical", m.physical)
                memRow("Used", m.used)
                memRow("Cached", m.cached)
                memRow("Swap", m.swap)
            }
            VStack(spacing: 2) {
                memRow("App", m.app)
                memRow("Wired", m.wired)
                memRow("Compressed", m.compressed)
            }
        }
    }

    func memRow(_ label: String, _ bytes: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9)).foregroundColor(.dim)
            Spacer(minLength: 4)
            Text(fmtGB(bytes)).font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.82))
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
    var hostingView: NSView?
    let model = OverlayModel()

    func fitToContent() {
        guard let panel = panel, let hosting = hostingView else { return }
        DispatchQueue.main.async {
            hosting.layoutSubtreeIfNeeded()
            let fit = hosting.fittingSize
            guard fit.width > 10, fit.height > 10 else { return }
            var f = panel.frame
            let top = f.maxY
            f.size = fit
            f.origin.y = top - fit.height   // keep top-left anchored
            panel.setFrame(f, display: true, animate: false)
            panel.invalidateShadow()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)     // show a Dock icon + app-switcher entry

        let hosting = ClickThroughHostingView(
            rootView: AnyView(OverlayView().environmentObject(model)))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hostingView = hosting
        model.onLayout = { [weak self] in self?.fitToContent() }

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
        // .managed (not .canJoinAllSpaces) keeps the panel on the single desktop Space it was
        // created on, so it doesn't follow you into a fullscreen app's Space — it stays behind
        // on the home/desktop where the Dock lives. .stationary keeps it fixed during Exposé.
        panel.collectionBehavior = [.managed, .stationary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.minSize = NSSize(width: 256, height: 200)
        panel.maxSize = NSSize(width: 1040, height: 1200)

        // restore saved position or default to top-right
        panel.setFrameAutosaveName("CCStatOverlayPanel")
        if panel.frame.origin == .zero {
            if let screen = NSScreen.main {
                let vf = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: vf.maxX - rect.width - 24, y: vf.maxY - rect.height - 24))
            }
        }
        // visible resize grip pinned flush to the bottom-right corner
        let grip = ResizeGrip(frame: .zero)
        grip.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.widthAnchor.constraint(equalToConstant: 16),
            grip.heightAnchor.constraint(equalToConstant: 16),
            grip.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -4),
            grip.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -4),
        ])

        panel.orderFrontRegardless()
        panel.invalidateShadow()
        fitToContent()   // size to current layout (vertical or horizontal), top-left anchored
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
