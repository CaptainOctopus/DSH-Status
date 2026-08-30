// 注意：不要显式 `import Darwin`。
// 在仅装 Command Line Tools（无 Xcode.app）的环境下，显式导入 Darwin 会触发
// `redefinition of module 'SwiftBridging'` 冲突；Foundation 本身已 re-export Darwin，
// host_statistics64 / socket 等符号照常可用。
import SwiftUI
import AppKit
import Foundation

// ============================================================================
// DSH Status —— macOS 菜单栏常驻应用
//
// 功能：
//   - 状态栏实时显示内存占用百分比（与「活动监视器」口径一致）
//   - 点开菜单可单独启停 DSH Web / 各个模型，或一键启停全套
//
// 实现要点：
//   - 内存直接用 Mach host_statistics64 读取，不 fork 子进程
//   - 端口探测用 BSD socket，彻底绕开系统代理（本机代理会拦截 localhost）
//   - 所有控制动作复用已有的 dsh-manager.sh，不重复实现启停逻辑
// ============================================================================

// MARK: - 配置

private let kScriptPath = "/Users/rory_zhang/WorkBuddy/2026-08-28-23-12-48/dsh-manager.sh"
private let kWebConsoleURL = "http://127.0.0.1:8899"

struct ManagedItem: Identifiable {
    let id: Int
    let title: String
    let port: Int
    let modelName: String?      // nil = DSH Web 服务（非模型后端）
}

private let kItems: [ManagedItem] = [
    ManagedItem(id: 3080, title: "DSH Web", port: 3080, modelName: nil),
    ManagedItem(id: 8000, title: "oMLX 9B/4B/14B", port: 8000, modelName: "omlx"),
    ManagedItem(id: 8001, title: "Qwen3-8B ablit", port: 8001, modelName: "qwen3-8b-ablit"),
    ManagedItem(id: 8002, title: "Qwen3-14B ablit", port: 8002, modelName: "qwen3-14b-ablit"),
]

// MARK: - 内存读取（对齐活动监视器「已使用内存」）

struct MemorySnapshot {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var available: UInt64 = 0
    var cached: UInt64 = 0
    var compressed: UInt64 = 0
    var free: UInt64 = 0
    var usedPct: Int = 0
}

func readMemory() -> MemorySnapshot {
    var snap = MemorySnapshot()
    let total = ProcessInfo.processInfo.physicalMemory
    snap.total = total

    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return snap }

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

    let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return snap }

    let ps = UInt64(pageSize)
    // 已用 = active + speculative + wired + compressor（压缩后实际占用）
    let usedPages = UInt64(stats.active_count)
        + UInt64(stats.speculative_count)
        + UInt64(stats.wire_count)
        + UInt64(stats.compressor_page_count)

    snap.used = min(usedPages * ps, total)
    snap.available = total - snap.used
    snap.cached = (UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)) * ps
    snap.compressed = UInt64(stats.compressor_page_count) * ps
    snap.free = UInt64(stats.free_count) * ps
    snap.usedPct = total > 0 ? Int(snap.used * 100 / total) : 0
    return snap
}

// MARK: - 端口探测（BSD socket，绕开系统代理）

func isPortOpen(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

// MARK: - 控制动作（复用 dsh-manager.sh）

func runManager(_ args: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [kScriptPath] + args
    var env = ProcessInfo.processInfo.environment
    env["no_proxy"] = "*"
    env["http_proxy"] = ""
    env["https_proxy"] = ""
    task.environment = env
    do {
        try task.run()
    } catch {
        NSLog("[DSHStatus] 执行 dsh-manager 失败: \(error)")
    }
}

// MARK: - 状态监控

final class StatusMonitor: ObservableObject {
    @Published var memory = MemorySnapshot()
    @Published var portState: [Int: Bool] = [:]
    @Published var busy: Set<Int> = []

    private let allKey = -1
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let snap = readMemory()
            var states: [Int: Bool] = [:]
            for item in kItems {
                states[item.port] = isPortOpen(item.port)
            }
            DispatchQueue.main.async {
                self.memory = snap
                self.portState = states
            }
        }
    }

    func toggle(_ item: ManagedItem) {
        let running = portState[item.port] ?? false
        busy.insert(item.port)
        if let model = item.modelName {
            runManager([running ? "unload" : "load", model])
        } else {
            runManager(["web", running ? "stop" : "start"])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.busy.remove(item.port)
            self.refresh()
        }
    }

    func startAll() {
        busy.insert(allKey)
        runManager(["start"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            self.busy.remove(self.allKey)
            self.refresh()
        }
    }

    func stopAll() {
        busy.insert(allKey)
        runManager(["stop"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.busy.remove(self.allKey)
            self.refresh()
        }
    }

    func isAllBusy() -> Bool { busy.contains(allKey) }
}

// MARK: - 格式化

func gb(_ bytes: UInt64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
}

// MARK: - 界面

struct MenuContent: View {
    @ObservedObject var monitor: StatusMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            memorySection
            Divider()
            ForEach(kItems) { item in
                ItemRow(item: item, monitor: monitor)
            }
            Divider()
            Button("▶ 启动全套") { monitor.startAll() }
                .disabled(monitor.isAllBusy())
            Button("■ 停止全部") { monitor.stopAll() }
                .disabled(monitor.isAllBusy())
            Divider()
            Button("打开网页控制台") {
                if let url = URL(string: kWebConsoleURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("立即刷新") { monitor.refresh() }
            Button("退出 DSH Status") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 290)
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("内存占用").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(monitor.memory.usedPct)%")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(colorForPct(monitor.memory.usedPct))
            }
            ProgressView(value: Double(monitor.memory.usedPct), total: 100.0)
                .tint(colorForPct(monitor.memory.usedPct))
            Text("已用 \(gb(monitor.memory.used)) · 可用 \(gb(monitor.memory.available))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("缓存 \(gb(monitor.memory.cached)) · 压缩 \(gb(monitor.memory.compressed))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func colorForPct(_ pct: Int) -> Color {
        if pct > 85 { return .red }
        if pct > 70 { return .orange }
        return .green
    }
}

struct ItemRow: View {
    let item: ManagedItem
    @ObservedObject var monitor: StatusMonitor

    private var running: Bool { monitor.portState[item.port] ?? false }
    private var isBusy: Bool { monitor.busy.contains(item.port) }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(running ? Color.green : Color.gray.opacity(0.45))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium))
                Text(":\(item.port)").font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button(isBusy ? "…" : (running ? "停止" : "启动")) {
                monitor.toggle(item)
            }
            .disabled(isBusy)
            .controlSize(.small)
        }
    }
}

// MARK: - App 入口

@main
struct DSHStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = StatusMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "memorychip")
                Text("\(monitor.memory.usedPct)%")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        //  accessory 策略 = 不显示 Dock 图标，只在菜单栏常驻
        NSApp.setActivationPolicy(.accessory)
    }
}
