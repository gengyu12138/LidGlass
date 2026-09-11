import AppKit
import IOKit.hid
import ScreenCaptureKit
import MetalKit
import CoreImage
import CoreImage.CIFilterBuiltins

final class LidSensor {
    private var device: IOHIDDevice?
    private(set) var error = "未找到角度传感器"

    init() { connect() }

    func connect() {
        if let device { IOHIDDeviceClose(device, 0) }
        device = nil
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x05ac,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8a
        ] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let found = devices.first else { return }
        let result = IOHIDDeviceOpen(found, 0)
        guard result == kIOReturnSuccess else {
            error = "角度传感器打开失败：\(result)"
            return
        }
        device = found
    }

    func read() -> Double? {
        guard let device else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        var length = bytes.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &length)
        guard result == kIOReturnSuccess, length >= 3, bytes[0] == 1 else {
            error = "角度读取失败：\(result)"
            return nil
        }
        // 传感器 Feature Report 1 以小端整数返回角度，非弧度。
        let angle = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        guard (0...180).contains(angle) else {
            error = "角度读数超出范围：\(angle)"
            return nil
        }
        return angle
    }

    deinit { if let device { IOHIDDeviceClose(device, 0) } }
}

final class GlassView: MTKView, MTKViewDelegate {
    private let context: CIContext
    private let queue: MTLCommandQueue
    var snapshot: CIImage?
    var progress: Double = 0

    init?(glassFrame frame: NSRect) {
        guard let gpu = MTLCreateSystemDefaultDevice(), let queue = gpu.makeCommandQueue() else { return nil }
        self.queue = queue
        context = CIContext(mtlDevice: gpu, options: [.cacheIntermediates: false])
        super.init(frame: frame, device: gpu)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        autoresizingMask = [.width, .height]
    }

    required init(coder: NSCoder) { fatalError("不使用 Storyboard") }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let source = snapshot, let drawable = currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        let p = CGFloat(progress)
        let extent = source.extent
        // Core Image 原点在左下：顶部白色达到最大模糊半径，向下过渡到黑色并恢复清晰。
        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: 0, y: extent.height * 0.95)
        gradient.point1 = CGPoint(x: 0, y: extent.height * 0.05)
        gradient.color0 = .white
        gradient.color1 = .black
        guard let mask = gradient.outputImage?.cropped(to: extent) else { return }
        var frame = source.clampedToExtent()
            .applyingFilter("CIMaskedVariableBlur", parameters: [
                kCIInputRadiusKey: 64 * p,
                "inputMask": mask
            ])
            .cropped(to: extent)
        frame = frame.transformed(by: CGAffineTransform(
            scaleX: drawableSize.width / extent.width,
            y: drawableSize.height / extent.height))
        context.render(frame, to: drawable.texture, commandBuffer: command,
                       bounds: CGRect(origin: .zero, size: drawableSize),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        command.present(drawable)
        command.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sensor = LidSensor()
    private var status: NSStatusItem!
    private let info = NSMenuItem(title: "读取角度…", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "启用角度动画", action: #selector(toggleEnabled), keyEquivalent: "")
    private var timer: Timer?
    private var window: NSWindow?
    private var glass: GlassView?
    private var enabled = true
    private var suspended = false
    private var suspensionReasons = Set<String>()
    private var captureError: String?
    private var captureTask: Task<Void, Never>?
    private var generation = 0
    private var target = 0.0
    private var progress = 0.0
    private var previewStart: TimeInterval?
    private var lastRead = 0.0
    private var lastValid = 0.0
    private var retryAfter = 0.0
    private var needsFreshCapture = true
    private var armed = false
    private var angleEffectActive = false
    private var controls: NSWindow?
    private let stateLabel = NSTextField(labelWithString: "正在连接")
    private let detailLabel = NSTextField(wrappingLabelWithString: "正在读取屏幕角度…")
    private let angleLabel = NSTextField(labelWithString: "—°")
    private let enableSwitch = NSSwitch()
    private let previewButton = NSButton(title: "播放开合动画", target: nil, action: nil)
    private let holdButton = NSButton(title: "保持预览", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复桌面", target: nil, action: nil)
    private var lastUIUpdate = 0.0
    private var lastPermissionCheck = 0.0
    private var captureAuthorized = false
    private var currentAngle: Double?
    private var holdingPreview = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "LidGlass")
        status.button?.toolTip = "LidGlass · 开合盖毛玻璃"
        let menu = NSMenu()
        menu.addItem(info)
        menu.addItem(.separator())
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)
        for (title, action) in [
            ("打开控制窗口", #selector(showControls)),
            ("预览一次开合动画", #selector(preview)),
            ("恢复桌面", #selector(restoreDesktop)),
            ("录屏权限设置…", #selector(requestCapture)),
            ("重新连接传感器", #selector(reconnect)),
            ("退出 LidGlass", #selector(quit))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        status.menu = menu
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(self, selector: #selector(pause), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(resume), name: name, object: nil)
        }
        // 锁屏时销毁快照，避免旧桌面内容在解锁前重新出现。
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(pause),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(resume),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        showControls()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return true
    }

    @objc private func showControls() {
        if controls == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "LidGlass"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.titlebarAppearsTransparent = true
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 20
            stack.translatesAutoresizingMaskIntoConstraints = false
            let icon = NSImageView(image: NSImage(named: "LidGlass") ?? NSApp.applicationIconImage)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
            let title = NSTextField(labelWithString: "LidGlass")
            title.font = .systemFont(ofSize: 28, weight: .semibold)
            let subtitle = NSTextField(labelWithString: "随开合，渐入朦胧。")
            subtitle.textColor = .secondaryLabelColor
            let identity = NSStackView(views: [title, subtitle])
            identity.orientation = .vertical
            identity.alignment = .leading
            identity.spacing = 6
            let header = NSStackView(views: [icon, identity])
            header.spacing = 16
            stack.addArrangedSubview(header)

            let card = NSBox()
            card.boxType = .custom
            card.titlePosition = .noTitle
            card.borderWidth = 0
            card.cornerRadius = 14
            card.fillColor = .controlBackgroundColor
            card.contentViewMargins = NSSize(width: 0, height: 0)
            let content = NSStackView()
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 12
            content.translatesAutoresizingMaskIntoConstraints = false
            angleLabel.font = .monospacedDigitSystemFont(ofSize: 36, weight: .medium)
            let angleCaption = NSTextField(labelWithString: "当前屏幕角度")
            angleCaption.textColor = .secondaryLabelColor
            let angleRow = NSStackView(views: [angleLabel, angleCaption])
            angleRow.spacing = 12
            content.addArrangedSubview(angleRow)
            stateLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            content.addArrangedSubview(stateLabel)
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = .secondaryLabelColor
            content.addArrangedSubview(detailLabel)
            card.contentView!.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor, constant: 18),
                content.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor, constant: -18),
                content.topAnchor.constraint(equalTo: card.contentView!.topAnchor, constant: 14),
                detailLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
                detailLabel.heightAnchor.constraint(equalToConstant: 36),
                card.heightAnchor.constraint(equalToConstant: 152)
            ])
            stack.addArrangedSubview(card)

            enableSwitch.target = self
            enableSwitch.action = #selector(toggleEnabled)
            let enableTitle = NSTextField(labelWithString: "随开合盖自动虚化")
            let spacer = NSView()
            let enableRow = NSStackView(views: [enableTitle, spacer, enableSwitch])
            enableRow.spacing = 10
            stack.addArrangedSubview(enableRow)

            previewButton.target = self
            previewButton.action = #selector(preview)
            holdButton.target = self
            holdButton.action = #selector(holdPreview)
            restoreButton.target = self
            restoreButton.action = #selector(restoreDesktop)
            restoreButton.keyEquivalent = "\u{1b}"
            for button in [previewButton, holdButton, restoreButton] { button.bezelStyle = .rounded }
            let actions = NSStackView(views: [previewButton, holdButton, restoreButton])
            actions.distribution = .fillEqually
            actions.spacing = 8
            stack.addArrangedSubview(actions)
            let guidance = NSTextField(wrappingLabelWithString:
                "顶部更朦胧，底部更清晰。合至 88° 进入，开至 92° 退出。\n预览期间可按 Esc 恢复桌面。")
            guidance.font = .systemFont(ofSize: 12)
            guidance.textColor = .secondaryLabelColor
            stack.addArrangedSubview(guidance)
            let settings = NSButton(title: "录屏权限设置…", target: self, action: #selector(requestCapture))
            let hide = NSButton(title: "收起到菜单栏", target: self, action: #selector(hideControls))
            settings.bezelStyle = .rounded
            hide.bezelStyle = .rounded
            let footer = NSStackView(views: [settings, NSView(), hide])
            stack.addArrangedSubview(footer)
            panel.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18)
            ])
            for view in [card, enableRow, actions, guidance, footer] {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            panel.center()
            controls = panel
        }
        controls?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateControls()
    }

    @objc private func hideControls() { controls?.orderOut(nil) }
    @objc private func restoreDesktop() { reset(); updateControls() }

    @objc private func holdPreview() {
        let shouldHold = !holdingPreview
        guard !shouldHold || canPreview() else { return }
        reset()
        if shouldHold {
            holdingPreview = true
            previewStart = CACurrentMediaTime() + 0.35
        }
        updateControls()
    }

    private func canPreview() -> Bool {
        captureAuthorized = CGPreflightScreenCaptureAccess()
        guard captureAuthorized, !suspended else { showControls(); return false }
        return true
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        toggle.state = enabled ? .on : .off
        reset()
        updateControls()
    }
    @objc private func reconnect() { sensor.connect(); retryAfter = 0 }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func pause(_ notification: Notification) {
        suspensionReasons.insert(pauseReason(notification.name))
        suspended = true
        reset()
    }
    @objc private func resume(_ notification: Notification) {
        suspensionReasons.remove(pauseReason(notification.name))
        suspended = !suspensionReasons.isEmpty
        guard !suspended else { return }
        sensor.connect()
        reset()
        armed = true
    }

    private func pauseReason(_ name: Notification.Name) -> String {
        switch name {
        case NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification: return "sleep"
        case NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification: return "display"
        case NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification: return "session"
        default: return "lock"
        }
    }
    @objc private func displayChanged() { reset(); window = nil; glass = nil }

    @objc private func requestCapture() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        retryAfter = 0
    }

    private func reset() {
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        window?.orderOut(nil)
        glass?.snapshot = nil
        previewStart = nil
        holdingPreview = false
        captureError = nil
        target = 0
        progress = 0
        armed = false
        angleEffectActive = false
        needsFreshCapture = true
    }

    @objc private func preview() {
        guard canPreview() else { return }
        reset()
        // 菜单完全关闭后再取快照，避免把菜单自身拍进去。
        previewStart = CACurrentMediaTime() + 0.35
        updateControls()
    }

    private func updateControls() {
        angleLabel.stringValue = currentAngle.map { "\(Int($0))°" } ?? "—°"
        enableSwitch.state = enabled ? .on : .off
        previewButton.isEnabled = captureAuthorized && !suspended
        holdButton.isEnabled = holdingPreview || (captureAuthorized && !suspended)
        holdButton.title = holdingPreview ? "结束预览" : "保持预览"
        restoreButton.isEnabled = previewStart != nil || captureTask != nil || glass?.snapshot != nil
        stateLabel.textColor = .labelColor
        if suspended {
            stateLabel.stringValue = "已暂停"
            detailLabel.stringValue = "屏幕关闭或电脑已锁定，回到桌面后继续。"
        } else if !captureAuthorized {
            stateLabel.stringValue = "需要录屏权限"
            stateLabel.textColor = .systemOrange
            detailLabel.stringValue = "点击下方“录屏权限设置”，允许 LidGlass 后按系统提示重新打开。"
        } else if let captureError {
            stateLabel.stringValue = "暂时无法获取画面"
            stateLabel.textColor = .systemOrange
            detailLabel.stringValue = captureError
        } else if captureTask != nil {
            stateLabel.stringValue = "正在准备画面"
            detailLabel.stringValue = "只在本机读取本轮桌面快照，请稍候。"
        } else if previewStart != nil {
            stateLabel.stringValue = holdingPreview ? "保持预览中" : "正在播放预览"
            detailLabel.stringValue = "点击“恢复桌面”或按 Esc 可立即结束。"
        } else if !enabled {
            stateLabel.stringValue = "自动虚化已关闭"
            detailLabel.stringValue = "仍可使用下方按钮预览，开启开关后恢复角度控制。"
        } else if currentAngle == nil {
            stateLabel.stringValue = "角度读取暂不可用"
            detailLabel.stringValue = "可手动预览，或在菜单栏中重新连接传感器。"
        } else if !armed {
            stateLabel.stringValue = "请先打开屏幕"
            detailLabel.stringValue = "将屏幕打开到 90° 以上，再缓慢合盖即可体验。"
        } else if progress > 0.0001, glass?.snapshot != nil {
            stateLabel.stringValue = "渐进虚化中 · \(Int(progress * 100))%"
            detailLabel.stringValue = "打开屏幕会逐渐恢复清晰，也可直接恢复桌面。"
        } else {
            stateLabel.stringValue = "已就绪"
            stateLabel.textColor = .systemGreen
            detailLabel.stringValue = "缓慢合至 88° 体验效果，或直接播放预览。"
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if now - lastPermissionCheck >= 1 {
            lastPermissionCheck = now
            captureAuthorized = CGPreflightScreenCaptureAccess()
        }
        if now - lastUIUpdate >= 0.2 {
            lastUIUpdate = now
            updateControls()
        }
        guard !suspended else { return }
        if now - lastRead >= 1.0 / 30 {
            lastRead = now
            if let angle = sensor.read() {
                lastValid = now
                currentAngle = angle
                info.title = "屏幕角度 \(Int(angle))° · 渐进虚化"
                if !captureAuthorized { info.title += " · 待授权" }
                else if let captureError { info.title += " · \(captureError)" }
                if angle >= 90 { armed = true }
                if previewStart == nil {
                    // 启动时已经处于低角度，不立即遮挡桌面；先打开到正常角度再触发。
                    // 进入和退出用不同阈值，防止整数读数在 90° 附近反复切换截图层。
                    if !enabled || !armed || angle >= 92 {
                        angleEffectActive = false
                    } else if angle <= 88 {
                        angleEffectActive = true
                    }
                    let raw = min(1, max(0, (90 - angle) / 75))
                    target = angleEffectActive ? raw * raw * (3 - 2 * raw) : 0
                }
            } else {
                currentAngle = nil
                info.title = sensor.error
                if now - lastValid > 0.5, previewStart == nil { reset() }
            }
        }
        if let start = previewStart {
            guard now >= start else { return }
            if glass?.snapshot == nil {
                target = 0.001
                capture()
                return
            }
            let phase = holdingPreview ? 0.5 : (now - start) / 3.2
            if phase >= 1 { reset(); return }
            target = pow(sin(phase * .pi), 2)
        }
        guard enabled || previewStart != nil else { return }
        if target > 0.0001, needsFreshCapture {
            capture()
        }
        let previous = progress
        progress += (target - progress) * 0.24
        if abs(target - progress) < 0.0005 { progress = target }
        guard let glass, glass.snapshot != nil else { return }
        if progress <= 0.0001, target == 0, !angleEffectActive {
            window?.orderOut(nil)
            glass.snapshot = nil
            needsFreshCapture = true
            return
        }
        if window?.isVisible != true || abs(previous - progress) > 0.00001 {
            glass.progress = progress
            glass.draw()
            // 弱虚化时逐渐混入截图，避免刚越过阈值就整屏替换真实桌面。
            window?.alphaValue = min(1, progress / 0.04)
            if window?.isVisible != true { window?.orderFrontRegardless() }
        }
    }

    private func capture() {
        guard captureTask == nil, CACurrentMediaTime() >= retryAfter,
              CGPreflightScreenCaptureAccess() else { return }
        let token = generation
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == generation { captureTask = nil } }
            do {
                guard let screen = NSScreen.screens.first(where: {
                    guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
                    return CGDisplayIsBuiltin(id) != 0
                }), let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                    throw NSError(domain: "LidGlass", code: 1, userInfo: [NSLocalizedDescriptionKey: "内置屏幕未连接"])
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    throw NSError(domain: "LidGlass", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法获取内置屏幕"])
                }
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                let config = SCStreamConfiguration()
                config.width = min(CGDisplayPixelsWide(id), 2048)
                config.height = Int(Double(config.width) * Double(CGDisplayPixelsHigh(id)) / Double(CGDisplayPixelsWide(id)))
                config.showsCursor = false
                config.captureResolution = .best
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard !Task.isCancelled, token == generation, !suspended,
                      target > 0 || angleEffectActive else { return }
                if window == nil {
                    guard let view = GlassView(glassFrame: NSRect(origin: .zero, size: screen.frame.size)) else {
                        throw NSError(domain: "LidGlass", code: 3, userInfo: [NSLocalizedDescriptionKey: "Metal 渲染不可用"])
                    }
                    let overlay = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    overlay.isReleasedWhenClosed = false
                    // 低于控制窗口一层，让“恢复桌面”始终可见。
                    overlay.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
                    overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                    overlay.ignoresMouseEvents = true
                    overlay.hasShadow = false
                    overlay.hidesOnDeactivate = false
                    overlay.alphaValue = 0
                    overlay.contentView = view
                    window = overlay
                    glass = view
                }
                glass?.snapshot = CIImage(cgImage: image)
                captureError = nil
                needsFreshCapture = false
                progress = 0
                if previewStart != nil { previewStart = CACurrentMediaTime() }
            } catch {
                guard token == generation else { return }
                captureError = "画面获取失败：\(error.localizedDescription)"
                retryAfter = CACurrentMediaTime() + 5
                window?.orderOut(nil)
                glass?.snapshot = nil
                previewStart = nil
                holdingPreview = false
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        reset()
    }
}

if CommandLine.arguments.contains("--status") {
    let sensor = LidSensor()
    if let angle = sensor.read() { print("Lid angle: \(angle) degrees") }
    else { print(sensor.error) }
    print("Screen capture authorized: \(CGPreflightScreenCaptureAccess())")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
