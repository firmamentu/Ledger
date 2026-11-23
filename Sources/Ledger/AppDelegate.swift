import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: AppPaths.bundleID, category: "lifecycle")
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var mainWindow: NSWindow?
    private var database: Database?
    private var lockFD: Int32?
    private var startupError: Error?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 单实例：持有排他锁直至进程退出；内核在退出时自动释放，崩溃不会留死锁。
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.supportDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            startupError = error
            return
        }

        let fd = open(AppPaths.lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        if fd < 0 {
            // open 失败（磁盘满/权限）≠ 已有实例：走 didFinish 的 fatal 弹窗
            let code = errno
            startupError = NSError(
                domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "无法创建单实例锁文件（errno \(code)）"]
            )
            return
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            logger.notice("Ledger 已在运行；本实例退出。")
            NSApp.terminate(nil)
            return
        }
        lockFD = fd
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard lockFD != nil else {
            if let startupError {
                presentFatalError(startupError)
            }
            return
        }

        NSApp.setActivationPolicy(.accessory)

        do {
            database = try Database(url: AppPaths.databaseURL)
            logger.notice("Ledger started; local ledger ready.")
        } catch {
            presentFatalError(error)
            return
        }

        installStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            logger.error("Status item has no button.")
            NSApp.terminate(nil)
            return
        }

        if let image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "Ledger") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "L"
        }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Ledger"

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "打开 Ledger", action: #selector(openLedger), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Ledger", action: #selector(quitLedger), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem = item
        statusMenu = menu
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp, let menu = statusMenu {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 4),
                in: sender
            )
        } else {
            showMainWindow()
        }
    }

    private func showMainWindow() {
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window

        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: RootView()))
        window.title = "Ledger"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 940, height: 620))
        window.minSize = NSSize(width: 780, height: 520)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.setFrameAutosaveName("LedgerMainWindow")
        return window
    }

    @objc private func openLedger() {
        showMainWindow()
    }

    @objc private func quitLedger() {
        NSApp.terminate(nil)
    }

    private func presentFatalError(_ error: Error) {
        logger.fault("Could not initialize the local ledger: \(error.localizedDescription, privacy: .public)")
        NSApp.activate()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "无法打开本地账本"
        alert.informativeText = "Ledger 需要在本机保存账本数据。\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "退出")
        alert.runModal()

        NSApp.terminate(nil)
    }
}
