import Foundation

/// 一台服务器的连接配置
public struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var alias: String       // 显示名，可留空
    public var host: String        // IP 或域名
    public var user: String        // SSH 用户名
    public var port: Int = 22

    public init(id: UUID = UUID(), alias: String = "", host: String = "", user: String = "", port: Int = 22) {
        self.id = id
        self.alias = alias
        self.host = host
        self.user = user
        self.port = port
    }

    /// user@host:port 形式的摘要；用户名留空表示按 ssh 配置别名连接
    public var summary: String {
        if user.trimmingCharacters(in: .whitespaces).isEmpty {
            return "按 ~/.ssh/config 连接"
        }
        var s = "\(user)@\(host)"
        if port != 22 { s += ":\(port)" }
        return s
    }

    public var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 一张 GPU 的状态（数值都来自 nvidia-smi，单位见字段名）
public struct GPUInfo: Hashable, Sendable {
    public let index: Int
    public let name: String
    public let uuid: String
    public let memUsedMiB: Int
    public let memTotalMiB: Int
    public let util: Int          // 利用率 0-100，读不到时为 0
    public let temp: Int          // 摄氏度，读不到时为 0

    public init(index: Int, name: String, uuid: String,
                memUsedMiB: Int, memTotalMiB: Int, util: Int, temp: Int) {
        self.index = index
        self.name = name
        self.uuid = uuid
        self.memUsedMiB = memUsedMiB
        self.memTotalMiB = memTotalMiB
        self.util = util
        self.temp = temp
    }

    public var memFrac: Double {
        memTotalMiB > 0 ? Double(memUsedMiB) / Double(memTotalMiB) : 0
    }

    /// 是否算空闲：利用率很低且基本没占显存
    public var isIdle: Bool {
        util < 5 && memUsedMiB <= max(512, Int(Double(memTotalMiB) * 0.03))
    }
}

/// 一张卡上跑的一个进程
public struct GPUProcess: Identifiable, Hashable, Sendable {
    public var id: Int { pid }
    public let pid: Int
    public let user: String
    public let name: String       // 完整命令路径
    public let memMiB: Int?       // 进程占用显存，某些驱动上读不到（nil）
    public let gpuIndex: Int
    public let elapsed: String    // 已运行时长，来自 ps，例如 "2-03:12:33"

    public init(pid: Int, user: String, name: String, memMiB: Int?, gpuIndex: Int, elapsed: String) {
        self.pid = pid
        self.user = user
        self.name = name
        self.memMiB = memMiB
        self.gpuIndex = gpuIndex
        self.elapsed = elapsed
    }

    /// 只显示命令的最后一段，比如 /usr/bin/python3.10 -> python3.10
    public var shortName: String {
        let last = (name as NSString).lastPathComponent
        return last.isEmpty ? name : last
    }

    public var memLabel: String {
        guard let m = memMiB else { return "—" }
        return m >= 1024 ? String(format: "%.1fG", Double(m) / 1024) : "\(m)M"
    }
}

public enum ServerPhase: Equatable {
    case idle
    case loading
    case ok
    case error(String)
}

/// 一台服务器的当前展示状态
public struct ServerState {
    public var config: ServerConfig
    public var phase: ServerPhase = .idle
    public var gpus: [GPUInfo] = []
    public var processes: [GPUProcess] = []
    public var updatedAt: Date? = nil
    public var refreshing: Bool = false

    public init(config: ServerConfig) {
        self.config = config
    }

    public var freeGPUCount: Int { gpus.filter(\.isIdle).count }
}

/// 小组件的显示方式
public enum DisplayMode: String, Codable {
    case desktop     // 钉在桌面层，被普通窗口遮挡（和系统小组件一样）
    case floating    // 悬浮在所有窗口之上
}

/// 显示相关的偏好设置（存在 UserDefaults 里）
public struct DisplayPrefs: Codable, Equatable {
    public var mode: DisplayMode = .desktop
    public var collapsed: Bool = false       // 迷你小条模式
    public var hotkeyEnabled: Bool = true
    // 默认 ⌥⇧G：kVK_ANSI_G=0x22，optionKey|shiftKey=0x0A00
    public var hotkeyCode: UInt32 = 0x22
    public var hotkeyMods: UInt32 = 0x0A00
    public var hotkeyLabel: String = "⌥⇧G"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(DisplayMode.self, forKey: .mode) ?? .desktop
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? true
        hotkeyCode = try c.decodeIfPresent(UInt32.self, forKey: .hotkeyCode) ?? 0x22
        hotkeyMods = try c.decodeIfPresent(UInt32.self, forKey: .hotkeyMods) ?? 0x0A00
        hotkeyLabel = try c.decodeIfPresent(String.self, forKey: .hotkeyLabel) ?? "⌥⇧G"
    }

    enum CodingKeys: String, CodingKey {
        case mode, collapsed, hotkeyEnabled, hotkeyCode, hotkeyMods, hotkeyLabel
    }
}

/// MiB 数值格式化成人们习惯的写法
public func fmtMem(_ mib: Int) -> String {
    mib >= 1024 ? String(format: "%.0fG", Double(mib) / 1024) : "\(mib)M"
}
