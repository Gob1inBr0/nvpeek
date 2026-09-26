import AppKit
import SwiftUI
import PDFKit
import Combine

/// 不抢焦点的面板：可以点按钮、右键，但不会把你正在用的窗口顶下去
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// 让 SwiftUI 内容支持"按背景拖动窗口"的宿主视图。
/// 这是社区对 NSHostingView 吞事件的通用修法：NSHostingView 默认不把
/// 鼠标事件透传给窗口的背景拖动机制，把 mouseDownCanMoveWindow 覆写为 true
/// 后，配合窗口的 isMovableByWindowBackground = true 才能拖起来；
/// SwiftUI 的按钮等交互元素仍会正常响应，不受影响。
final class MovableHostingView: NSHostingView<PanelView> {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
public final class PanelController {
    private let store: MonitorStore
    private let panel: NonActivatingPanel
    private var settingsWindow: NSWindow?
    private var changeCancellable: AnyCancellable?
    private var eventMonitor: Any?
    // 手动拖动状态：非 nil 表示正在拖
    private var dragStartMouse: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private let debugLog = ProcessInfo.processInfo.environment["NVPEEK_DEBUG"] == "1"
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
        // 配合 MovableHostingView 的 mouseDownCanMoveWindow = true 实现按背景拖动
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

        // 独立拖动通道 1：本地事件监视器（在事件总线层面，不依赖任何视图转发）。
        // 只负责标题栏条带；窗口其他区域交给 SwiftUI 的 WindowDragGesture。
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMouseEvent(event)
        }

        applyDisplayModeIfNeeded()
        applyHotKeyIfNeeded()
        positionPanel()

        // 独立拖动通道 2 的维护 + 显示设置生效：AppKit 会缓存窗口"可拖动区域"，
        // 而本程序界面每几秒刷新一次，缓存容易失效（Chromium/Firefox 都记录过
        // 这个行为）。数据变化时把开关关掉再打开，强制它重新计算。
        changeCancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.panel.isMovableByWindowBackground = false
                self.panel.isMovableByWindowBackground = true
                self.applyDisplayModeIfNeeded()
                self.applyHotKeyIfNeeded()
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

    // MARK: - 手动窗口拖动（通道 1：事件监视器 + 直接挪窗口）

    private func log(_ text: String) {
        guard debugLog else { return }
        FileHandle.standardError.write(Data(("[nvpeek drag] \(text)\n").utf8))
    }

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            guard event.window === panel else {
                log("mouseDown 在别的窗口（\(event.window.map { String($0.windowNumber) } ?? "nil"))")
                return event
            }
            guard let content = panel.contentView else { return event }
            let p = content.convert(event.locationInWindow, from: nil)
            let inTopStrip = p.y >= content.bounds.height - 44
            let inButtonZone = p.x >= content.bounds.width - 160
            log("mouseDown p=\(p) 高=\(content.bounds.height) 条带=\(inTopStrip) 按钮区=\(inButtonZone)")
            guard inTopStrip, !inButtonZone else { return event }
            dragStartMouse = NSEvent.mouseLocation
            dragStartWindowOrigin = panel.frame.origin
            return nil
        case .leftMouseDragged:
            guard dragStartMouse != nil, let startMouse = dragStartMouse,
                  let origin = dragStartWindowOrigin else { return event }
            let now = NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(x: origin.x + (now.x - startMouse.x),
                                         y: origin.y + (now.y - startMouse.y)))
            return nil
        case .leftMouseUp:
            guard dragStartMouse != nil else { return event }
            dragStartMouse = nil
            dragStartWindowOrigin = nil
            return nil
        default:
            return event
        }
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
