import AppKit
import nvpeekCore

// main.swift 的顶层代码就跑在主线程上，用 assumeIsolated 进入主 actor。
// 不能用 Task { @MainActor }：顶层函数返回后进程就退出了，app.run() 保不住。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // 不在 Dock 显示图标、不抢占焦点，像一个桌面小挂件
    app.setActivationPolicy(.accessory)
    app.run()
}
