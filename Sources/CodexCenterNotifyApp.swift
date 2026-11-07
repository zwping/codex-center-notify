import AppKit
import CoreGraphics
import Darwin
import Foundation

private let antigravityBundleID = "com.google.antigravity-ide"
private let lockPath = "/tmp/codex-center-notify.lock"
private let notificationDuration: TimeInterval = 5
private let visualTestDuration: TimeInterval = 20
private let notificationSourceText = "Antigravity · Codex"

private struct CompletionEvent {
    let project: String?
    let title: String?
    let summary: String?

    static func parse(_ argument: String?) -> CompletionEvent? {
        guard let argument, let data = argument.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "agent-turn-complete" else { return nil }
        let cwd = object["cwd"] as? String
        let project = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let message = object["last-assistant-message"] as? String
        let normalized = normalize(message)
        let titleLimit = 24
        let titleContentLength = normalized.map { min($0.count, titleLimit) } ?? 0
        let title = preview(normalized, limit: titleLimit)
        let continuation = normalized.map { String($0.dropFirst(titleContentLength)) }
        return CompletionEvent(project: project?.isEmpty == false ? project : nil,
                               title: title,
                               summary: preview(continuation, limit: 60))
    }

    static func testEvent() -> CompletionEvent {
        let message = String(repeating: "摘要测试：任务已完成，结果已保存。", count: 8)
        return parse("""
        {"type":"agent-turn-complete","cwd":"/tmp/Antigravity 通知测试","last-assistant-message":"\(message)"}
        """) ?? CompletionEvent(project: "Antigravity 通知测试", title: "测试完成", summary: nil)
    }

    private static func normalize(_ message: String?) -> String? {
        guard let message else { return nil }
        let normalized = message.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func preview(_ message: String?, limit: Int) -> String? {
        guard let message, !message.isEmpty else { return nil }
        guard message.count > limit else { return message }
        return String(message.prefix(limit - 1)) + "…"
    }
}

private func takeDisplayLock() -> Int32? {
    let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        Darwin.close(descriptor)
        return nil
    }
    return descriptor
}

private func cgWindowRect(_ value: Any?) -> CGRect? {
    guard let bounds = value as? NSDictionary,
          let x = bounds["X"] as? NSNumber,
          let y = bounds["Y"] as? NSNumber,
          let width = bounds["Width"] as? NSNumber,
          let height = bounds["Height"] as? NSNumber else { return nil }
    return CGRect(x: x.doubleValue, y: y.doubleValue,
                  width: width.doubleValue, height: height.doubleValue)
}

private func antigravityScreen() -> NSScreen? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: antigravityBundleID).first else {
        return nil
    }
    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    let appWindows = windows.compactMap { item -> CGRect? in
        let ownerPID = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let ownerName = (item[kCGWindowOwnerName as String] as? String)?.lowercased() ?? ""
        guard ownerPID == app.processIdentifier || ownerName.contains("antigravity"),
              (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
        return cgWindowRect(item[kCGWindowBounds as String])
    }.sorted { ($0.width * $0.height) > ($1.width * $1.height) }

    guard let window = appWindows.first else { return nil }
    return NSScreen.screens.max { lhs, rhs in
        func overlapArea(_ screen: NSScreen) -> CGFloat {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 0 }
            let display = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let overlap = window.intersection(display)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        return overlapArea(lhs) < overlapArea(rhs)
    }
}

private final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        let trackingArea = NSTrackingArea(rect: .zero,
                                          options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self,
                                          userInfo: nil)
        addTrackingArea(trackingArea)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

private final class NotificationController: NSObject, NSApplicationDelegate {
    private let event: CompletionEvent?
    private let lockDescriptor: Int32
    private let testLogPath: String?
    private let duration: TimeInterval
    private let hoverInteractionsEnabled: Bool
    private var panel: NSPanel?
    private var closeButton: NSButton?
    private var closeTimer: DispatchWorkItem?
    private var isHovered = false
    private var didFinish = false
    private var startedAt = Date()
    private var initialFrontPID: pid_t = 0

    init(event: CompletionEvent?, lockDescriptor: Int32, testLogPath: String?, duration: TimeInterval,
         hoverInteractionsEnabled: Bool) {
        self.event = event
        self.lockDescriptor = lockDescriptor
        self.testLogPath = testLogPath
        self.duration = duration
        self.hoverInteractionsEnabled = hoverInteractionsEnabled
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        initialFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        startedAt = Date()
        guard let screen = antigravityScreen() ?? NSScreen.main ?? NSScreen.screens.first else {
            finish()
            return
        }

        let hasSummary = event?.summary != nil
        let size = NSSize(width: hasSummary ? 460 : 390,
                          height: hasSummary ? 212 : (event?.project == nil ? 134 : 158))
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let card = HoverTrackingView(frame: NSRect(origin: .zero, size: size))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedRed: 0.105, green: 0.112, blue: 0.13, alpha: 0.97).cgColor
        card.layer?.cornerRadius = 18
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor

        let closeButton = NSButton(frame: .zero)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭通知")
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        closeButton.toolTip = "关闭通知"
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        closeButton.layer?.cornerRadius = 14
        closeButton.layer?.cornerCurve = .circular
        closeButton.layer?.masksToBounds = true
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeNotification)
        self.closeButton = closeButton
        card.onHoverChanged = { [weak self] isHovered in
            guard let self, self.hoverInteractionsEnabled else { return }
            self.setHoverState(isHovered)
        }

        let source = NSTextField(labelWithString: notificationSourceText)
        source.font = .systemFont(ofSize: 11, weight: .medium)
        source.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        source.alignment = .center

        let title = NSTextField(labelWithString: event?.title ?? "任务已完成")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        title.alignment = .center
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [source, title])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = hasSummary ? 6 : 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.addSubview(closeButton, positioned: .above, relativeTo: nil)

        if let project = event?.project {
            let detail = NSTextField(labelWithString: "项目 · \(project)")
            detail.font = .systemFont(ofSize: 13, weight: .regular)
            detail.textColor = NSColor(calibratedWhite: 0.70, alpha: 1)
            detail.alignment = .center
            stack.addArrangedSubview(detail)
        }

        if let summary = event?.summary {
            let summaryLabel = NSTextField(wrappingLabelWithString: summary)
            summaryLabel.font = .systemFont(ofSize: 12, weight: .regular)
            summaryLabel.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
            summaryLabel.alignment = .center
            summaryLabel.maximumNumberOfLines = 3
            summaryLabel.preferredMaxLayoutWidth = size.width - 48
            summaryLabel.widthAnchor.constraint(equalToConstant: size.width - 48).isActive = true
            stack.addArrangedSubview(summaryLabel)
        }

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -24),
            closeButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        panel.contentView = card
        self.panel = panel
        panel.orderFrontRegardless()
        let soundStarted = playGlass()
        if let testLogPath {
            writeTestLine("TEST_POLICY raw=\(NSApplication.shared.activationPolicy().rawValue) bundle=\(Bundle.main.bundleIdentifier ?? "-")", to: testLogPath)
            writeTestLine("TEST_SHOWN frontmost_pid=\(initialFrontPID)", to: testLogPath)
            writeTestLine("TEST_TITLE uses_reply=\(event?.title != nil) chars=\(event?.title?.count ?? 0)", to: testLogPath)
            writeTestLine("TEST_SOURCE rendered=\(source.stringValue == notificationSourceText)", to: testLogPath)
            writeTestLine("TEST_PROJECT rendered=\(event?.project != nil)", to: testLogPath)
            writeTestLine("TEST_SUMMARY chars=\(event?.summary?.count ?? 0) rendered=\(event?.summary != nil)", to: testLogPath)
            writeTestLine("TEST_FOCUS active=\(NSApplication.shared.isActive) panel_key=\(panel.isKeyWindow)", to: testLogPath)
            let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
            let listed = windows.contains {
                ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == panel.windowNumber
            }
            writeTestLine("TEST_WINDOW visible=\(panel.isVisible) number=\(panel.windowNumber) server_listed=\(listed)", to: testLogPath)
            writeTestLine("TEST_SOUND Glass started=\(soundStarted ? 1 : 0)", to: testLogPath)
        }

        scheduleAutoClose()
    }

    private func setHoverState(_ hovered: Bool) {
        guard !didFinish else { return }
        isHovered = hovered
        closeTimer?.cancel()
        closeTimer = nil
        closeButton?.isHidden = !hovered
        if let testLogPath {
            writeTestLine("TEST_HOVER inside=\(hovered) close_visible=\(closeButton?.isHidden == false) image=\(closeButton?.image != nil)", to: testLogPath)
        }
        if !hovered {
            finish()
        }
    }

    private func scheduleAutoClose() {
        closeTimer?.cancel()
        guard !didFinish, !isHovered else { return }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovered else { return }
            self.finish()
        }
        closeTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: timer)
    }

    @objc private func closeNotification() {
        if let testLogPath {
            writeTestLine("TEST_CLOSE_ACTION clicked=true", to: testLogPath)
        }
        finish()
    }

    private func playGlass() -> Bool {
        let sound = NSSound(named: NSSound.Name("Glass"))
            ?? NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)
        guard let sound else { return false }
        return sound.play()
    }

    private func writeTestLine(_ line: String, to path: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            _ = FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        closeTimer?.cancel()
        closeTimer = nil
        panel?.orderOut(nil)
        panel?.close()
        if let testLogPath {
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            let active = NSApplication.shared.isActive
            writeTestLine(String(format: "TEST_CLOSED elapsed=%.2f frontmost_pid=%d app_active=%@", Date().timeIntervalSince(startedAt), frontPID, active ? "true" : "false"), to: testLogPath)
        }
        Darwin.close(lockDescriptor)
        NSApplication.shared.terminate(nil)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let visualTest = arguments.first == "--test-visual"
let testIndex = arguments.firstIndex(of: "--test")
let visualIndex = arguments.firstIndex(of: "--test-visual")
let displayIndex = arguments.firstIndex(of: "--display-event")
let testMode = testIndex != nil || visualTest
let logIndex = testIndex ?? visualIndex
let testLogPath = logIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
private let parsedEvent = displayIndex.flatMap { $0 + 1 < arguments.count ? CompletionEvent.parse(arguments[$0 + 1]) : nil }
private let event = testMode ? CompletionEvent.testEvent() : parsedEvent

guard testMode || event != nil, let lockDescriptor = takeDisplayLock() else { exit(EXIT_FAILURE) }
private let app = NSApplication.shared
private let controller = NotificationController(event: event,
                                                lockDescriptor: lockDescriptor,
                                                testLogPath: testLogPath,
                                                duration: visualTest ? visualTestDuration : notificationDuration,
                                                hoverInteractionsEnabled: !testMode || visualTest)
app.delegate = controller
app.run()
