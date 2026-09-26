import Foundation
import Combine

@MainActor
public final class MonitorStore: ObservableObject {
    @Published public private(set) var configs: [ServerConfig]
    @Published public private(set) var states: [UUID: ServerState] = [:]
    @Published public private(set) var interval: TimeInterval
    @Published public private(set) var prefs: DisplayPrefs

    /// 演示模式：不连真服务器，显示假数据（用来预览外观）
    public let demo: Bool

    private var inFlight: Set<UUID> = []
    private var loop: Task<Void, Never>?

    public init() {
        let (loaded, iv, loadedPrefs) = Persistence.load()
        configs = loaded
        interval = iv
        prefs = loadedPrefs
        demo = ProcessInfo.processInfo.environment["NVPEEK_DEMO"] == "1"
        if demo && configs.isEmpty {
            configs = [
                ServerConfig(alias: "示例·8 卡训练机", host: "demo-a.lab", user: "chen", port: 22),
                ServerConfig(alias: "示例·连不上的机器", host: "demo-b.lab", user: "chen", port: 22),
            ]
        }
        syncStates()
    }

    // MARK: - 轮询

    public func start() {
        pollAll()
        restartLoop()
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.pollAll()
            }
        }
    }

    public func pollAll() {
        for config in configs where config.isComplete {
            poll(config)
        }
    }

    public func poll(_ config: ServerConfig) {
        guard !inFlight.contains(config.id) else { return }
        inFlight.insert(config.id)
        states[config.id]?.refreshing = true
        if demo {
            pollDemo(config)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await SSHRunner.run(config: config, timeout: 12)
                let parsed = try Parser.parse(stdout: result.stdout, stderr: result.stderr)
                var st = self.states[config.id] ?? ServerState(config: config)
                st.gpus = parsed.gpus
                st.processes = parsed.processes
                st.phase = .ok
                st.updatedAt = Date()
                st.refreshing = false
                self.states[config.id] = st
            } catch {
                var st = self.states[config.id] ?? ServerState(config: config)
                st.phase = .error(Self.describe(error))
                st.refreshing = false
                self.states[config.id] = st
            }
            self.inFlight.remove(config.id)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SSHError.timeout:
            return "连接超时（12 秒内没有响应），检查网络或机器是否在线"
        case SSHError.launchFailed(let msg):
            return "无法启动 ssh：\(msg)"
        case ParseError.remote(let msg):
            return msg
        case ParseError.badOutput(let msg):
            return "nvidia-smi 输出解析失败：\(msg)"
        default:
            let hint = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
            if let hint = hint, !hint.isEmpty { return "连接失败：\(hint)" }
            return "出错：\(error.localizedDescription)"
        }
    }

    // MARK: - 服务器增删改

    public func addServer(_ config: ServerConfig) {
        configs.append(config)
        syncStates()
        persistNow()
        poll(config)
    }

    public func updateServer(_ config: ServerConfig) {
        guard let i = configs.firstIndex(where: { $0.id == config.id }) else { return }
        configs[i] = config
        states[config.id]?.config = config
        persistNow()
        poll(config)
    }

    public func removeServer(_ id: UUID) {
        configs.removeAll { $0.id == id }
        states[id] = nil
        persistNow()
    }

    public func setInterval(_ value: TimeInterval) {
        guard value != interval else { return }
        interval = value
        persistNow()
        restartLoop()
    }

    // MARK: - 显示偏好

    public func setDisplayMode(_ mode: DisplayMode) {
        updatePrefs { $0.mode = mode }
    }

    public func setCollapsed(_ value: Bool) {
        updatePrefs { $0.collapsed = value }
    }

    public func setHotkeyEnabled(_ value: Bool) {
        updatePrefs { $0.hotkeyEnabled = value }
    }

    public func setHotKey(keyCode: UInt32, modifiers: UInt32, label: String) {
        updatePrefs {
            $0.hotkeyCode = keyCode
            $0.hotkeyMods = modifiers
            $0.hotkeyLabel = label
        }
    }

    private func updatePrefs(_ transform: (inout DisplayPrefs) -> Void) {
        var next = prefs
        transform(&next)
        guard next != prefs else { return }
        prefs = next
        persistNow()
    }

    public var intervalLabel: String { "\(Int(interval)) 秒" }

    public var anyRefreshing: Bool {
        states.values.contains { $0.refreshing }
    }

    /// 服务器列表变化后，让状态表和配置表保持一致
    private func syncStates() {
        let ids = Set(configs.map(\.id))
        states = states.filter { ids.contains($0.key) }
        for c in configs where states[c.id] == nil {
            states[c.id] = ServerState(config: c)
        }
    }

    private func persistNow() {
        guard !demo else { return }   // 演示数据不写进用户配置
        Persistence.save(configs: configs, interval: interval, prefs: prefs)
    }

    // MARK: - 演示模式假数据

    private func pollDemo(_ config: ServerConfig) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, var st = self.states[config.id] else { return }
            defer { self.inFlight.remove(config.id) }
            if config.alias.contains("连不上") {
                st.phase = .error("ssh: connect to host demo-b.lab port 22: Operation timed out")
                st.refreshing = false
                self.states[config.id] = st
                return
            }
            let users = ["chen", "wang", "li", "zhang"]
            let names = ["python3.10", "train_llm.py", "vllm", "torchrun"]
            st.gpus = (0..<8).map { i in
                let roll = Int.random(in: 0...100)
                let busy = roll >= 35
                let util = busy ? Int.random(in: 20...100) : Int.random(in: 0...3)
                let used = busy ? Int.random(in:20_000...40_000) : Int.random(in: 200...600)
                return GPUInfo(index: i, name: "NVIDIA A100-SXM4-40GB", uuid: "GPU-demo-\(i)",
                               memUsedMiB: used, memTotalMiB: 40_960, util: util,
                               temp: 38 + util / 4)
            }
            var procs: [GPUProcess] = []
            for g in st.gpus where !g.isIdle {
                let n = Int.random(in: 1...2)
                for _ in 0..<n {
                    procs.append(GPUProcess(
                        pid: Int.random(in: 10_000...99_999),
                        user: users.randomElement()!,
                        name: names.randomElement()!,
                        memMiB: g.memUsedMiB / n,
                        gpuIndex: g.index,
                        elapsed: "\(Int.random(in: 0...3))-\(String(format: "%02d", Int.random(in: 0...23))):\(String(format: "%02d", Int.random(in: 0...59))):\(String(format: "%02d", Int.random(in: 0...59)))"))
                }
            }
            st.processes = procs.sorted { $0.gpuIndex < $1.gpuIndex }
            st.phase = .ok
            st.updatedAt = Date()
            st.refreshing = false
            self.states[config.id] = st
        }
    }
}
