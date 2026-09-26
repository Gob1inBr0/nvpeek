import AppKit
import SwiftUI
import PDFKit
import Combine

/// 不抢焦点的面板：可以点按钮、右键，但不会把你正在用的窗口顶下去
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// 能拖动窗口的宿主视图。NSHostingView 会拦下鼠标事件，藏在它背后的把手视图
/// 收不到按下事件；所以在它自己的 mouseDown 里分流：点在标题栏条带
/// （右侧按钮区除外）就执行系统窗口拖动，其余位置照常交给 SwiftUI 处理。
final class MovableHostingView: NSHostingView<PanelView> {
    /// 标题栏条带高度（展开态标题行和迷你条都在窗口顶部）
    private let dragStripHeight: CGFloat = 40
    /// 右侧按钮区宽度，这个范围里不拖动，留给按钮点击
    private let buttonZoneWidth: CGFloat = 150

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inTopStrip = point.y >= bounds.height - dragStripHeight
        let inButtonZone = point.x >= bounds.width - buttonZoneWidth
        if inTopStrip && !inButtonZone, let window = window {
            window.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
public final class PanelController {
    private let store: MonitorStore
    private let panel: NonActivatingPanel
    private var settingsWindow: NSWindow?
    private var changeCancellable: AnyCancellable?
    private var appliedMode: DisplayMode?
    private var appliedHotKey: HotKeyId?

    /// 快捷键标识（元组没法直接比较，包一层）
    private struct HotKeyId: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    public init(store: MonitorStore) {
        self.store = store

        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 324, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = "nvpeek"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // 到这里存储属性都已初始化，闭包才可以安全捕获 self
        let root = PanelView(
            store: store,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) },
            onContentHeight: { [weak self] height in
                self?.resizePanel(toContentHeight: height)
            })
        let hosting = MovableHostingView(rootView: root)
        panel.contentView = hosting

        applyDisplayModeIfNeeded()
        applyHotKeyIfNeeded()
        positionPanel()

        // 显示方式、快捷键设置变化时立即生效
        changeCancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.applyDisplayModeIfNeeded()
                self?.applyHotKeyIfNeeded()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            guard let frame = panel?.frame else { return }
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: Persistence.Keys.panelFrame)
        }
    }

    public func show() {
        panel.orderFrontRegardless()
        maybeSnapshotForDebug()
    }

    /// 顶栏菜单和全局快捷键共用：整个小组件隐藏/显示
    public var isPanelVisible: Bool { panel.isVisible }

    public func toggleVisible() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// 调试用：设置环境变量 NVPEEK_SNAPSHOT=/path/to.png，
    /// 程序显示 2.5 秒后把自己的窗口存成图片，然后退出。截自己的窗口不需要屏幕录制权限。
    private func maybeSnapshotForDebug() {
        guard let path = ProcessInfo.processInfo.environment["NVPEEK_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            FileHandle.standardError.write(Data(("collapsed=\(self?.store.prefs.collapsed.description ?? "nil") mode=\(self?.store.prefs.mode.rawValue ?? "nil")\n").utf8))
            let ok = Self.writeSnapshot(panel: self?.panel, toPath: path)
            FileHandle.standardError.write(Data(("snapshot ok=\(ok)\n").utf8))
            NSApp.terminate(nil)
        }
    }

    static func writeSnapshot(panel: NSPanel?, toPath path: String) -> Bool {
        guard let panel, let contentView = panel.contentView else { return false }
        FileHandle.standardError.write(Data(("panel frame=\(panel.frame) content=\(contentView.bounds) fit=\(contentView.fittingSize)\n").utf8))
        // 先写一份按图层渲染的图（更接近真实屏幕显示），文件名后缀 -layer
        if let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) {
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path + "-layer.png"))
            }
        }
        // 首选：把窗口内容离屏渲染成 PDF，再转成 PNG（不需要任何权限，真实绘制内容）
        let pdfData = contentView.dataWithPDF(inside: contentView.bounds)
        try? pdfData.write(to: URL(fileURLWithPath: path + ".pdf"))
        if !pdfData.isEmpty,
           let pdfDocument = PDFDocument(data: pdfData),
           let page = pdfDocument.page(at: 0) {
            let size = CGSize(width: contentView.bounds.width * 2,
                              height: contentView.bounds.height * 2)
            let image = page.thumbnail(of: size, for: .mediaBox)
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                return true
            }
        }
        // 备用：按窗口编号截自己的真实画面（在新系统上没有屏幕录制权限时可能返回黑图）
        let windowID = CGWindowID(panel.windowNumber)
        if windowID != 0,
           let cgImage = CGWindowListCreateImage(.null, [.optionIncludingWindow], windowID, [.bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                return true
            }
        }
        return false
    }

    public func openSettings() {
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "nvpeek · 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 窗口高度跟随 SwiftUI 汇报的内容高度，左上角保持不动，且不出屏幕
    private func resizePanel(toContentHeight height: CGFloat) {
        guard height > 1 else { return }
        // 下限放得很低：迷你小条只有几十点高
        let newHeight = min(max(height, 56), 620)
        guard abs(newHeight - panel.frame.height) > 1 else { return }
        let oldFrame = panel.frame
        panel.setContentSize(NSSize(width: 324, height: newHeight))
        var origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - newHeight)
        if let visible = panel.screen?.visibleFrame {
            origin.y = max(origin.y, visible.minY)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - 324)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - 显示方式和全局快捷键

    /// 按设置切换窗口层级：钉在桌面层（被窗口遮挡）或悬浮在所有窗口之上
    private func applyDisplayModeIfNeeded() {
        let mode = store.prefs.mode
        guard mode != appliedMode else { return }
        appliedMode = mode
        switch mode {
        case .desktop:
            // 和系统桌面小组件同层：贴在壁纸上，被普通窗口自然遮挡
            // 桌面图标层再抬高 1 级：Finder 的桌面窗口也在图标层，
            // 同层时谁后露头谁在上，Finder 会把自己排前面、抢走所有点击；
            // 高 1 级既点得到，仍然远在普通窗口之下、照样被工作窗口遮挡
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .floating:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        }
    }

    /// 快捷键设置变化时重新注册；关闭时注销
    private func applyHotKeyIfNeeded() {
        let prefs = store.prefs
        let key: HotKeyId? = prefs.hotkeyEnabled
            ? HotKeyId(keyCode: prefs.hotkeyCode, modifiers: prefs.hotkeyMods)
            : nil
        guard key != appliedHotKey else { return }
        appliedHotKey = key
        if let key {
            HotKeyCenter.shared.register(keyCode: key.keyCode, modifiers: key.modifiers) { [weak self] in
                self?.toggleVisible()
            }
        } else {
            HotKeyCenter.shared.unregister()
        }
    }

    /// 恢复上次位置（如果那块屏幕还在），否则放到主屏右上角
    private func positionPanel() {
        if let saved = UserDefaults.standard.string(forKey: Persistence.Keys.panelFrame) {
            let rect = NSRectFromString(saved)
            if rect.width > 0, NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) {
                panel.setFrameOrigin(rect.origin)
                return
            }
        }
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 16,
            y: visible.maxY - size.height - 12))
    }
}
