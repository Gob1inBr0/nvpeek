import AppKit
import nvpeekCore

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 不在 Dock 显示图标、不抢占焦点，像一个桌面小挂件
app.setActivationPolicy(.accessory)
app.run()
