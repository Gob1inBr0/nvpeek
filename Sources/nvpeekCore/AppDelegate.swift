import AppKit
import Combine

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MonitorStore!
    private var panelController: PanelController!
    private var statusItem: NSStatusItem?
    private var menuCancellable: AnyCancellable?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        store = MonitorStore()
        panelController = PanelController(store: store)
        panelController.show()
        store.start()
        setupStatusItem()
    }

    // MARK: - 顶栏（状态栏）图标和菜单

    /// 状态栏小图标：一幅小 GPU 图形，绿色小点表示至少有一台在线
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.statusIcon(online: false)

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // 数据变化时更新菜单标题上的空闲汇总和小图标状态
        menuCancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let states = self.statusStates() else { return }
                item.button?.image = Self.statusIcon(online: states.contains { $0 })
                item.button?.toolTip = self.statusSummary(states)
            }
        }
    }

    private func statusStates() -> [Bool]? {
        guard !store.configs.isEmpty else { return nil }
        return store.configs.map { config in
            if case .ok = store.states[config.id]?.phase { return true }
            return false
        }
    }

    private func statusSummary(_ online: [Bool]) -> String {
        var parts: [String] = []
        for config in store.configs {
            guard let state = store.states[config.id] else { continue }
            let name = config.alias.isEmpty ? config.host : config.alias
            if case .ok = state.phase {
                parts.append("\(name) 空闲 \(state.freeGPUCount)/\(state.gpus.count)")
            } else if case .error(let message) = state.phase {
                parts.append("\(name) 不可用")
                _ = message
            }
        }
        return parts.isEmpty ? "nvpeek" : "nvpeek · " + parts.joined(separator: "，")
    }

    /// 16×16 状态栏图形：一块矩形芯片，中间三格显存条，右下角状态点
    static func statusIcon(online: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let bodyColor = NSColor.labelColor.withAlphaComponent(0.85)
            // 芯片主体（圆角矩形）
            let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4, width: 11, height: 8),
                                    xRadius: 2, yRadius: 2)
            bodyColor.setStroke()
            body.lineWidth = 1.2
            body.stroke()
            // 中间的三格显存条
            bodyColor.setFill()
            for (i, frac) in [0.9, 0.5, 0.2].enumerated() {
                let bar = NSRect(x: 3.2 + CGFloat(i) * 3.0, y: 6.5,
                                 width: 2.0, height: 3.0 * frac)
                NSBezierPath(rect: bar).fill()
            }
            // 左右引脚
            for y in [5.8, 10.2] {
                NSBezierPath(rect: NSRect(x: 0, y: y, width: 1.5, height: 0.9)).fill()
                NSBezierPath(rect: NSRect(x: 13, y: y, width: 1.5, height: 0.9)).fill()
            }
            // 在线状态点（右下角）
            let dot = NSBezierPath(ovalIn: NSRect(x: 11.5, y: 1.5, width: 4, height: 4))
            (online ? NSColor.systemGreen : NSColor.systemGray).setFill()
            dot.fill()
            return true
        }
        image.isTemplate = true   // 自动适配深浅色菜单栏
        return image
    }

    /// 弹出菜单前刷新每一项的状态
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let visible = isPanelVisible()
        let visibility = NSMenuItem(title: visible ? "隐藏小组件" : "显示小组件",
                                    action: #selector(togglePanel), keyEquivalent: "h")
        visibility.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(visibility)

        let collapsed = store.prefs.collapsed
        let mini = NSMenuItem(title: collapsed ? "展开详情" : "收起为迷你条",
                              action: #selector(toggleMini), keyEquivalent: "m")
        mini.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(mini)

        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r"))

        menu.addItem(.separator())
        let modeLabel = store.prefs.mode == .desktop ? "当前：钉在桌面" : "当前：悬浮在最前"
        menu.addItem(withTitle: modeLabel, action: nil, keyEquivalent: "")
        let mode = NSMenuItem(title: "切换到\(store.prefs.mode == .desktop ? "悬浮在最前" : "钉在桌面")",
                              action: #selector(toggleMode), keyEquivalent: "")
        menu.addItem(mode)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "退出 nvpeek", action: #selector(quitApp), keyEquivalent: "q"))
    }

    private func isPanelVisible() -> Bool {
        panelController.isPanelVisible
    }

    // MARK: - 菜单动作

    @objc private func togglePanel() { panelController.toggleVisible() }
    @objc private func toggleMini() { store.setCollapsed(!store.prefs.collapsed) }
    @objc private func refreshNow() { store.pollAll() }
    @objc private func toggleMode() {
        store.setDisplayMode(store.prefs.mode == .desktop ? .floating : .desktop)
    }
    @objc private func openSettings() { panelController.openSettings() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }
}
