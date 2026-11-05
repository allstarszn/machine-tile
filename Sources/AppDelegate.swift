import AppKit
import Combine
import SwiftUI

/// Borderless, floats over every Space, and can be dragged from anywhere on its
/// own background rather than from a title bar it does not have.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let machineModel = MachineModel()
    private var machinePanel: FloatingPanel?
    private var machineHotkey: Hotkey?
    private var machineStatusItem: NSStatusItem?
    private var machineSink: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        machineHotkey = Hotkey { [weak self] in self?.toggleMachine() }
        buildMachineStatusItem()
        buildMachinePanel()
        showMachine()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func buildMachineStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                            accessibilityDescription: "Machine Tile")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.target = self
        item.button?.action = #selector(machineStatusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Machine Tile"
        machineStatusItem = item
    }

    @objc private func machineStatusClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Quit Machine Tile", action: #selector(quit), keyEquivalent: "q")
                .target = self
            machineStatusItem?.menu = menu
            machineStatusItem?.button?.performClick(nil)
            machineStatusItem?.menu = nil
        } else {
            toggleMachine()
        }
    }

    private func buildMachinePanel() {
        let controller = NSHostingController(
            rootView: MachineView(model: machineModel, onClose: { [weak self] in self?.hideMachine() },
                                  onResize: { [weak self] in DispatchQueue.main.async { self?.fitMachinePanel() } }))
        let window = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 272, height: 400),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        window.contentViewController = controller
        window.isFloatingPanel = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        machinePanel = window

        // The panel grows and shrinks with its content (a stuck-lane list appears and
        // goes), so re-fit after every new reading, holding the top edge still.
        machineSink = machineModel.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitMachinePanel() }
        }
    }

    private func fitMachinePanel() {
        guard let panel = machinePanel, panel.isVisible,
              let view = panel.contentViewController?.view else { return }
        let fitting = view.fittingSize
        guard fitting.width > 0, fitting.height > 0,
              abs(fitting.height - panel.frame.height) > 0.5 || abs(fitting.width - panel.frame.width) > 0.5
        else { return }
        let top = panel.frame.maxY
        panel.setContentSize(fitting)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
    }

    private func placeMachinePanel() {
        guard let panel = machinePanel else { return }
        let defaults = UserDefaults.standard
        if let x = defaults.object(forKey: "machinePanelX") as? Double,
           let y = defaults.object(forKey: "machinePanelY") as? Double,
           NSScreen.screens.contains(where: { $0.frame.contains(CGPoint(x: x, y: y)) }) {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24,
                                     y: frame.maxY - panel.frame.height - 12))
    }

    private func toggleMachine() {
        guard let panel = machinePanel else { return }
        if panel.isVisible { hideMachine() } else { showMachine() }
    }

    private func showMachine() {
        guard let panel = machinePanel else { return }
        if let view = panel.contentViewController?.view {
            let fitting = view.fittingSize
            if fitting.width > 0, fitting.height > 0 { panel.setContentSize(fitting) }
        }
        placeMachinePanel()
        panel.orderFrontRegardless()
        machineModel.start()      // polling exists only while the panel is open
    }

    private func hideMachine() {
        guard let panel = machinePanel else { return }
        UserDefaults.standard.set(Double(panel.frame.minX), forKey: "machinePanelX")
        UserDefaults.standard.set(Double(panel.frame.minY), forKey: "machinePanelY")
        panel.orderOut(nil)
        machineModel.stop()
    }
}
