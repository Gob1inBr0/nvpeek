import Foundation

public enum Persistence {
    public enum Keys {
        public static let servers = "gpuwidget.servers.v1"
        public static let interval = "gpuwidget.interval"
        public static let panelFrame = "gpuwidget.panelFrame"
        public static let displayPrefs = "gpuwidget.display.v1"
    }

    /// 项目原名 GPUWidget（包标识 com.chen.gpu-widget），改名 nvpeek 后
    /// 首次运行时把旧配置搬过来，用户不会丢已添加的服务器和偏好
    private static let legacyDomain = "com.chen.gpu-widget"

    static func save(configs: [ServerConfig], interval: TimeInterval, prefs: DisplayPrefs) {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(configs) {
            d.set(data, forKey: Keys.servers)
        }
        d.set(interval, forKey: Keys.interval)
        if let data = try? JSONEncoder().encode(prefs) {
            d.set(data, forKey: Keys.displayPrefs)
        }
    }

    static func load() -> ([ServerConfig], TimeInterval, DisplayPrefs) {
        migrateLegacyIfNeeded()
        let d = UserDefaults.standard
        var configs: [ServerConfig] = []
        if let data = d.data(forKey: Keys.servers),
           let c = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            configs = c
        }
        let interval = d.double(forKey: Keys.interval)
        var prefs = DisplayPrefs()
        if let data = d.data(forKey: Keys.displayPrefs),
           let p = try? JSONDecoder().decode(DisplayPrefs.self, from: data) {
            prefs = p
        }
        return (configs, interval >= 2 ? interval : 5, prefs)
    }

    /// 新包标识下还没有任何配置、旧包标识下有 → 把旧数据整体搬过来
    private static func migrateLegacyIfNeeded() {
        let d = UserDefaults.standard
        let hasNewData = d.data(forKey: Keys.servers) != nil || d.double(forKey: Keys.interval) != 0
        guard !hasNewData,
              let legacy = UserDefaults(suiteName: legacyDomain),
              let domain = legacy.persistentDomain(forName: legacyDomain),
              !domain.isEmpty else { return }
        for (key, value) in domain where key.hasPrefix("gpuwidget.") {
            d.set(value, forKey: key)
        }
    }
}

/// 开机自启：往 ~/Library/LaunchAgents 写一个启动配置文件
public enum LoginItem {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.chen.nvpeek.plist")
    }

    static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.chen.gpu-widget.plist")
    }

    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public static func setEnabled(_ on: Bool) throws {
        let fm = FileManager.default
        // 旧版本的启动配置一并清掉，避免开机同时拉起新旧两个程序
        if fm.fileExists(atPath: legacyPlistURL.path) {
            try? fm.removeItem(at: legacyPlistURL)
        }
        guard on else {
            if fm.fileExists(atPath: plistURL.path) {
                try fm.removeItem(at: plistURL)
            }
            return
        }
        // 直接跑二进制时没有 .app 包，没法配自启
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            throw NSError(domain: "LoginItem", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请通过 nvpeek.app 启动后再设置开机自启"])
        }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/nvpeek").path
        let plist = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.chen.nvpeek</string>
            <key>ProgramArguments</key>
            <array><string>\(binary)</string></array>
            <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }
}
