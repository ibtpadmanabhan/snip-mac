// Snip — a Windows-11-style Snipping Tool for macOS (MVP)
// Modes: Rectangle / Window / Full screen, delay timer, editor (pen, highlighter), copy, save.
// Hotkey: Control+Shift+S

import Cocoa
import Carbon.HIToolbox

enum Mode: Int { case rectangle = 0, window, fullscreen, freeform }

struct SnipResult {
    var rect: NSRect          // cocoa global, integral
    var path: [NSPoint]?      // cocoa global points for free-form
}

// MARK: - Helpers

func sym(_ name: String, _ desc: String) -> NSImage {
    NSImage(systemSymbolName: name, accessibilityDescription: desc)
        ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: desc)!
}

var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

/// Cocoa global (bottom-left origin) rect -> screencapture/CG global (top-left origin) rect
func toTopLeft(_ r: NSRect) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

func windowRect(at p: NSPoint) -> NSRect? {
    let tl = CGPoint(x: p.x, y: primaryHeight - p.y)
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return nil }
    let me = ProcessInfo.processInfo.processIdentifier
    for w in list {  // ordered front to back
        guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
              let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
              let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0,
              let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
              r.contains(tl), r.width > 20, r.height > 20 else { continue }
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    return nil
}

// MARK: - Selection overlay

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class OverlayView: NSView {
    unowned let session: SnipSession
    init(session: SnipSession, frame: NSRect) {
        self.session = session
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func viewDidMoveToWindow() {
        guard window != nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let win = window, let gc = NSGraphicsContext.current else { return }
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        func local(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x - win.frame.minX, y: p.y - win.frame.minY) }
        if session.mode == .freeform {
            guard session.path.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: local(session.path[0]))
            for p in session.path.dropFirst() { path.line(to: local(p)) }
            gc.saveGraphicsState()
            path.addClip()
            gc.compositingOperation = .copy
            NSColor.white.withAlphaComponent(0.01).setFill()
            bounds.fill()
            gc.restoreGraphicsState()
            NSColor.white.setStroke()
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            path.stroke()
            return
        }
        guard let r = session.rect else { return }
        let lr = r.offsetBy(dx: -win.frame.minX, dy: -win.frame.minY)
        // Punch a (nearly) clear hole; alpha must stay >0 so the window still receives mouse events.
        gc.compositingOperation = .copy
        NSColor.white.withAlphaComponent(0.01).setFill()
        lr.fill()
        gc.compositingOperation = .sourceOver
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: lr.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1.5
        path.stroke()
    }

    override func mouseDown(with e: NSEvent) { session.down(NSEvent.mouseLocation) }
    override func mouseDragged(with e: NSEvent) { session.drag(NSEvent.mouseLocation) }
    override func mouseUp(with e: NSEvent) { session.up(NSEvent.mouseLocation) }
    override func mouseMoved(with e: NSEvent) { session.move(NSEvent.mouseLocation) }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == UInt16(kVK_Escape) { session.finish(nil) } else { super.keyDown(with: e) }
    }
}

final class SnipSession {
    let mode: Mode
    let done: (SnipResult?) -> Void
    var windows: [OverlayWindow] = []
    var start: NSPoint?
    var rect: NSRect?
    var path: [NSPoint] = []

    init(mode: Mode, done: @escaping (SnipResult?) -> Void) {
        self.mode = mode
        self.done = done
    }

    func begin() {
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        var keyView: OverlayView?
        for s in NSScreen.screens {
            let w = OverlayWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            let v = OverlayView(session: self, frame: NSRect(origin: .zero, size: s.frame.size))
            w.contentView = v
            w.setFrame(s.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
            if NSMouseInRect(mouse, s.frame, false) || keyView == nil { keyView = v }
        }
        keyView?.window?.makeKeyAndOrderFront(nil)
        keyView?.window?.makeFirstResponder(keyView)
        if mode == .window { move(mouse) }
    }

    func refresh() { windows.forEach { $0.contentView?.needsDisplay = true } }

    func down(_ p: NSPoint) {
        switch mode {
        case .window: if let r = rect { finish(SnipResult(rect: r.integral, path: nil)) }
        case .rectangle: start = p; rect = NSRect(origin: p, size: .zero)
        case .freeform: path = [p]
        case .fullscreen: break
        }
    }
    func drag(_ p: NSPoint) {
        switch mode {
        case .rectangle:
            guard let s = start else { return }
            rect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            refresh()
        case .freeform:
            guard !path.isEmpty else { return }
            path.append(p)
            refresh()
        default: break
        }
    }
    func up(_ p: NSPoint) {
        switch mode {
        case .rectangle:
            guard start != nil, let r = rect else { return }
            if r.width < 4 || r.height < 4 { start = nil; rect = nil; refresh(); return }
            finish(SnipResult(rect: r.integral, path: nil))
        case .freeform:
            guard path.count > 3 else { path = []; refresh(); return }
            let xs = path.map { $0.x }, ys = path.map { $0.y }
            let r = NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).integral
            if r.width < 4 || r.height < 4 { path = []; refresh(); return }
            finish(SnipResult(rect: r, path: path))
        default: break
        }
    }
    func move(_ p: NSPoint) {
        guard mode == .window else { return }
        rect = windowRect(at: p)
        refresh()
    }
    func finish(_ r: SnipResult?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        done(r)
    }
}


// MARK: - Canvas (shows the current snip, lets you draw on it)

struct Stroke {
    var points: [NSPoint]
    var color: NSColor
    var width: CGFloat
    var highlighter: Bool
}

final class Canvas: NSView {
    static let pad: CGFloat = 28
    var image: NSImage?
    var strokes: [Stroke] = []
    var current: Stroke?
    var highlighter = false
    var color = NSColor.systemRed
    var width: CGFloat = 4
    var onSave: (() -> Void)?
    var onNew: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { if image != nil { addCursorRect(bounds, cursor: .crosshair) } }

    func setImage(_ img: NSImage?) {
        image = img
        strokes = []
        current = nil
        setFrameSize(img.map { NSSize(width: $0.size.width + 2 * Canvas.pad, height: $0.size.height + 2 * Canvas.pad) } ?? .zero)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func drawContent() {
        guard let image else { return }
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        for s in strokes + (current.map { [$0] } ?? []) {
            guard let first = s.points.first else { continue }
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = s.highlighter ? s.width * 4 : s.width
            path.move(to: first)
            if s.points.count == 1 { path.line(to: NSPoint(x: first.x + 0.01, y: first.y)) }
            for p in s.points.dropFirst() { path.line(to: p) }
            (s.highlighter ? s.color.withAlphaComponent(0.4) : s.color).setStroke()
            path.stroke()
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let gc = NSGraphicsContext.current else { return }
        gc.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: Canvas.pad, yBy: Canvas.pad)
        t.concat()
        let imgRect = NSRect(origin: .zero, size: image.size)
        // soft shadow that follows the snip's shape
        gc.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.4)
        sh.shadowBlurRadius = 14
        sh.shadowOffset = .zero
        sh.set()
        image.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        gc.restoreGraphicsState()
        drawContent()
        // thin outline just outside the snip
        if showOutline {
            NSColor.separatorColor.setStroke()
            let o = NSBezierPath(rect: imgRect.insetBy(dx: -0.5, dy: -0.5))
            o.lineWidth = 1
            o.stroke()
        }
        gc.restoreGraphicsState()
    }
    var showOutline = true

    func imagePoint(_ e: NSEvent) -> NSPoint {
        let p = convert(e.locationInWindow, from: nil)
        return NSPoint(x: p.x - Canvas.pad, y: p.y - Canvas.pad)
    }

    override func mouseDown(with e: NSEvent) {
        guard image != nil else { return }
        window?.makeFirstResponder(self)
        current = Stroke(points: [imagePoint(e)], color: color, width: width, highlighter: highlighter)
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        current?.points.append(imagePoint(e))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        if let c = current { strokes.append(c) }
        current = nil
        needsDisplay = true
    }

    func undo() { if !strokes.isEmpty { strokes.removeLast(); needsDisplay = true } }

    /// Full-resolution PNG (pixel size of the original capture) with annotations baked in.
    func pngData() -> Data? {
        guard let image else { return nil }
        let rep0 = image.representations.first
        let pw = rep0?.pixelsWide ?? Int(image.size.width)
        let ph = rep0?.pixelsHigh ?? Int(image.size.height)
        guard pw > 0, ph > 0,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        let cg = gc.cgContext
        cg.translateBy(x: 0, y: CGFloat(ph))
        cg.scaleBy(x: CGFloat(pw) / image.size.width, y: -CGFloat(ph) / image.size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        drawContent()
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])
    }

    func copyToClipboard() {
        guard let png = pngData(), let img = NSImage(data: png) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let c = e.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: e) }
        switch c {
        case "c": copyToClipboard()
        case "z": undo()
        case "s": onSave?()
        case "n": onNew?()
        case "w": window?.close()
        default: return super.performKeyEquivalent(with: e)
        }
        return true
    }
}

/// Crop-by-shape for free-form snips: pixels outside the drawn path become transparent.
func maskedImage(_ img: NSImage, path: [NSPoint], rect: NSRect) -> NSImage {
    let rep0 = img.representations.first
    let pw = rep0?.pixelsWide ?? Int(img.size.width)
    let ph = rep0?.pixelsHigh ?? Int(img.size.height)
    guard pw > 0, ph > 0,
          let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: out) else { return img }
    let cg = gc.cgContext
    cg.translateBy(x: 0, y: CGFloat(ph))
    cg.scaleBy(x: CGFloat(pw) / img.size.width, y: -CGFloat(ph) / img.size.height)
    let cp = CGMutablePath()
    for (i, p) in path.enumerated() {
        let pt = CGPoint(x: p.x - rect.minX, y: rect.maxY - p.y)   // image coords, top-left origin
        i == 0 ? cp.move(to: pt) : cp.addLine(to: pt)
    }
    cp.closeSubpath()
    cg.addPath(cp)
    cg.clip()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    img.draw(in: NSRect(origin: .zero, size: img.size), from: .zero, operation: .sourceOver,
             fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    out.size = img.size
    let res = NSImage(size: img.size)
    res.addRepresentation(out)
    return res
}

/// Keeps the (smaller-than-window) snip centered instead of stuck in the top-left corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        if let doc = documentView {
            if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
            if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        }
        return r
    }
}

// MARK: - The one and only window

final class MainController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let canvas = Canvas()
    let emptyLabel = NSTextField(labelWithString: "Click New or press ⌃⇧S to take a snip")
    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let delayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let toolControl = NSSegmentedControl(
        images: [sym("pencil.tip", "Pen"), sym("highlighter", "Highlighter")],
        trackingMode: .selectOne, target: nil, action: nil)
    let colorWell = NSColorWell()
    let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var imageControls: [NSControl] = []
    var onNew: () -> Void = {}

    var mode: Mode { Mode(rawValue: modePopup.indexOfSelectedItem) ?? .rectangle }
    var delay: Int { [0, 3, 5, 10][max(0, delayPopup.indexOfSelectedItem)] }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 380),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Snip"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 240)
        window.delegate = self
        canvas.onSave = { [weak self] in self?.save() }
        canvas.onNew = { [weak self] in self?.onNew() }

        // Left: New + mode + delay
        let newBtn = NSButton(title: " New", image: sym("plus", "New"), target: self, action: #selector(newTapped))
        newBtn.imagePosition = .imageLeading
        newBtn.bezelStyle = .rounded
        newBtn.bezelColor = .controlAccentColor
        newBtn.toolTip = "New snip (⌃⇧S)"
        for (t, i) in [("Rectangle", "rectangle.dashed"), ("Window", "macwindow"),
                       ("Monitor", "display"), ("Free-form", "scribble")] {
            modePopup.addItem(withTitle: t)
            modePopup.lastItem?.image = sym(i, t)
        }
        modePopup.toolTip = "Snip mode"
        for t in ["No delay", "3 seconds", "5 seconds", "10 seconds"] {
            delayPopup.addItem(withTitle: t)
            delayPopup.lastItem?.image = sym("timer", t)
        }
        delayPopup.toolTip = "Delay"

        // Center: drawing tools
        toolControl.target = self
        toolControl.action = #selector(toolChanged)
        toolControl.selectedSegment = 0
        toolControl.setToolTip("Pen", forSegment: 0)
        toolControl.setToolTip("Highlighter", forSegment: 1)
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        if #available(macOS 13.0, *) { colorWell.colorWellStyle = .minimal }
        colorWell.widthAnchor.constraint(equalToConstant: 34).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        widthPopup.addItems(withTitles: ["Thin", "Medium", "Thick"])
        widthPopup.selectItem(at: 1)
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged)

        func iconButton(_ name: String, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(image: sym(name, tip), target: self, action: sel)
            b.isBordered = false
            b.toolTip = tip
            return b
        }
        let undoBtn = iconButton("arrow.uturn.backward", "Undo (⌘Z)", #selector(undoTapped))
        // Right: Copy + Save
        let copyBtn = iconButton("doc.on.doc", "Copy (⌘C)", #selector(copyTapped))
        let saveBtn = iconButton("square.and.arrow.down", "Save (⌘S)", #selector(saveTapped))
        imageControls = [toolControl, colorWell, widthPopup, undoBtn, copyBtn, saveBtn]

        let sp1 = NSView(), sp2 = NSView()
        for sp in [sp1, sp2] { sp.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal) }
        let bar = NSStackView(views: [newBtn, modePopup, delayPopup, sp1,
                                      toolControl, colorWell, widthPopup, undoBtn, sp2, copyBtn, saveBtn])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        sp1.widthAnchor.constraint(equalTo: sp2.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(bar)
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        window.contentView = content
        window.center()
        setImage(nil)
    }

    func setImage(_ img: NSImage?) {
        canvas.setImage(img)
        emptyLabel.isHidden = img != nil
        imageControls.forEach { $0.isEnabled = img != nil }
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let w = img.map { max(640, min($0.size.width + 2 * Canvas.pad, vis.width * 0.85)) } ?? 640
        let h = img.map { 48 + max(160, min($0.size.height + 2 * Canvas.pad, vis.height * 0.8)) } ?? 380
        window.setContentSize(NSSize(width: w, height: h))
        if img != nil { window.center() }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    @objc func newTapped() { onNew() }
    @objc func toolChanged() {
        canvas.highlighter = toolControl.selectedSegment == 1
        let c: NSColor = canvas.highlighter ? .systemYellow : .systemRed
        colorWell.color = c
        canvas.color = c
    }
    @objc func colorChanged() { canvas.color = colorWell.color }
    @objc func widthChanged() { canvas.width = [2, 4, 8][max(0, widthPopup.indexOfSelectedItem)] }
    @objc func undoTapped() { canvas.undo() }
    @objc func copyTapped() { canvas.copyToClipboard() }
    @objc func saveTapped() { save() }

    func save() {
        guard canvas.image != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        panel.nameFieldStringValue = "Screenshot \(f.string(from: Date())).png"
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let data = self?.canvas.pngData() else { return }
            try? data.write(to: url)
        }
    }

    // Closing the window throws the snip away — nothing is stored unless you pressed Save.
    func windowWillClose(_ notification: Notification) { setImage(nil) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    let main = MainController()
    var session: SnipSession?
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        main.onNew = { [weak self] in self?.newSnip() }
        setupStatusItem()
        registerHotKey()
        main.show()
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = sym("scissors", "Snip")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {      // right-click: small menu
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Snip", action: #selector(openWindow), keyEquivalent: "").target = self
            menu.addItem(withTitle: "New Snip  (⌃⇧S)", action: #selector(newSnipMenu), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Snip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            openWindow()                                     // left-click: open the window
        }
    }
    @objc func openWindow() { main.show() }
    @objc func newSnipMenu() { newSnip() }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AppDelegate.shared.newSnip() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x534E4950), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | shiftKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func newSnip() {
        guard session == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Screen Recording permission needed"
            a.informativeText = "Allow “Snip” under System Settings → Privacy & Security → Screen Recording, then quit and reopen Snip."
            a.addButton(withTitle: "Open System Settings")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let mode = main.mode
        let delay = main.delay
        let wasVisible = main.window.isVisible
        main.window.orderOut(nil)          // get the window out of the way, then grab immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? Double(delay) : 0.2)) { [self] in
            if mode == .fullscreen {
                let loc = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) } ?? NSScreen.main!
                capture(SnipResult(rect: screen.frame, path: nil))
            } else {
                let s = SnipSession(mode: mode) { [weak self] result in
                    self?.session = nil
                    if let result { self?.capture(result) } else if wasVisible { self?.main.show() }
                }
                session = s
                s.begin()
            }
        }
    }

    func capture(_ result: SnipResult) {
        let r = toTopLeft(result.rect)
        // Small pause so the overlay is fully gone from the screen before grabbing pixels.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let tmp = NSTemporaryDirectory() + "snip-\(UUID().uuidString).png"
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-R", "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))", tmp]
                try? p.run()
                p.waitUntilExit()
                DispatchQueue.main.async { [self] in
                    defer { try? FileManager.default.removeItem(atPath: tmp) }   // temp file never kept
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: tmp)), var img = NSImage(data: data) else { NSSound.beep(); main.show(); return }
                    if let path = result.path { img = maskedImage(img, path: path, rect: result.rect) }
                    main.setImage(img)
                    main.show()
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
