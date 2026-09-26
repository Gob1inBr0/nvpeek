import AppKit
import SwiftUI
import Carbon.HIToolbox

/// 系统级全局快捷键（Carbon 热键接口，不需要辅助功能权限）
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        unregister()
        installEventHandlerIfNeeded()
        self.action = action
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x67707764, id: 1)   // "gpwd"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        action = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in center.action?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }
}

/// 设置界面里的"按下组合键"录制框
struct HotKeyRecorderView: NSViewRepresentable {
    var onCapture: (_ keyCode: UInt32, _ modifiers: UInt32, _ label: String) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
    }

    final class RecorderView: NSView {
        var onCapture: ((UInt32, UInt32, String) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { window?.makeFirstResponder(self) }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == UInt16(kVK_Escape) {
                onCancel?()
                return
            }
            var modifiers: UInt32 = 0
            if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }

            // 只按修饰键不算一条快捷键
            let modifierKeyCodes: Set<UInt16> = [
                UInt16(kVK_Shift), UInt16(kVK_RightShift),
                UInt16(kVK_Option), UInt16(kVK_RightOption),
                UInt16(kVK_Command), UInt16(kVK_RightCommand),
                UInt16(kVK_Control), UInt16(kVK_RightControl),
                UInt16(kVK_Function), UInt16(kVK_CapsLock),
            ]
            guard modifiers != 0, !modifierKeyCodes.contains(event.keyCode) else {
                NSSound.beep()
                return
            }

            var label = ""
            if modifiers & UInt32(controlKey) != 0 { label += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { label += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { label += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { label += "⌘" }
            label += (event.charactersIgnoringModifiers ?? "").uppercased()

            onCapture?(UInt32(event.keyCode), modifiers, label)
        }
    }
}
