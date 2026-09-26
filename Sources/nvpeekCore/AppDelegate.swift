import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MonitorStore!
    private var panelController: PanelController!

    public func applicationDidFinishLaunching(_ notification: Notification) {
        store = MonitorStore()
        panelController = PanelController(store: store)
        panelController.show()
        store.start()
    }
}
