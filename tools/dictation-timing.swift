// Build with swiftc -O -parse-as-library into an app bundle (see tools/README.md).
import AppKit
import ScreenCaptureKit
import CoreImage

final class Frames: NSObject, SCStreamOutput {
    let lock = NSLock()
    private var start: UInt64?
    private var first: Double?
    var output = "/tmp/fluid-visible.png"
    func begin(_ value: UInt64) { lock.withLock { start = value } }
    var visible: Double? { lock.withLock { first } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let start = lock.withLock({ first == nil ? start : nil }), type == .screen,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer), width = CVPixelBufferGetWidth(buffer)
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
                if pixel[3] > 32 && Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) > 180 { count += 1 }
            }
        }
        guard count > 100 else { return }
        lock.withLock { first = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }
        if let image = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: width, height: height)),
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: output))
        }
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let background = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    let frames = Frames()
    var window: NSWindow!, field: NSTextView!, stream: SCStream!
    var insertion: UInt64?
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), edit = NSMenuItem(), editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu = editMenu; menu.addItem(edit); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 150, y: 450, width: 600, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Disposable dictation timing field"
        field = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        field.isEditable = true; field.font = .systemFont(ofSize: 20)
        window.contentView = field; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field); NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: field)
        Task { @MainActor in await measure() }
    }
    @objc func textChanged() { if insertion == nil, !field.string.isEmpty { insertion = DispatchTime.now().uptimeNanoseconds } }
    func key(_ down: Bool) {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 61, keyDown: down)!
        event.type = .flagsChanged; event.flags = down ? .maskAlternate : []; event.post(tap: .cghidEventTap)
    }
    func measure() async {
        defer { key(false) }
        do {
            let args = CommandLine.arguments
            frames.output = args.count > 1 ? args[1] : "/tmp/fluid-visible.png"
            let audio = args.count > 2 ? args[2] : nil
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let fluid = content.applications.first(where: { $0.bundleIdentifier == "com.FluidApp.app" }) else { throw NSError(domain: "FluidVoice not running", code: 1) }
            let pointer = CGEvent(source: nil)!.location
            guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(pointer) }) else { throw NSError(domain: "No pointer display", code: 1) }
            let excluded = content.windows.filter { $0.owningApplication?.processID == fluid.processID && $0.frame.height > 250 }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: Double(display.height - 220), width: Double(display.width), height: 220)
            config.pixelFormat = kCVPixelFormatType_32BGRA; config.width = display.width; config.height = 220
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60); config.showsCursor = false; config.queueDepth = 3; config.backgroundColor = background
            stream = SCStream(filter: SCContentFilter(display: display, including: [fluid], exceptingWindows: excluded), configuration: config, delegate: nil)
            try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "dictation.frames"))
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(1))
            let start = DispatchTime.now().uptimeNanoseconds
            frames.begin(start); key(true)
            // Controlled busy-target test; capture continues on its private queue.
            if args.contains("--stall-focus") { usleep(2_000_000) }
            var windowSeconds: Double?
            for _ in 0..<240 {
                let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
                if windowSeconds == nil, rows.contains(where: { row in
                    guard row[kCGWindowOwnerName as String] as? String == "FluidVoice", let bounds = row[kCGWindowBounds as String] as? [String: Any], let height = bounds["Height"] as? Double, let width = bounds["Width"] as? Double else { return false }
                    return height > 30 && height < 250 && width > 120
                }) { windowSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }
                if frames.visible != nil { break }
                try await Task.sleep(for: .milliseconds(15))
            }
            guard frames.visible != nil else { throw NSError(domain: "Recording pixels not observed", code: 2) }
            if let audio {
                let playback = Process(); playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); playback.arguments = [audio]
                try playback.run()
                while playback.isRunning { try await Task.sleep(for: .milliseconds(50)) }
                try await Task.sleep(for: .milliseconds(300))
            } else { try await Task.sleep(for: .seconds(1)) }
            key(false)
            let stop = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<(audio == nil ? 20 : 300) {
                if insertion != nil { break }; try await Task.sleep(for: .milliseconds(50))
            }
            try await stream.stopCapture()
            let passed = field.string.lowercased().filter { $0.isLetter } == "hellofluidvoice"
            let result: [String: Any] = ["keyPostedUptimeNs": start, "windowSeconds": windowSeconds.map { $0 as Any } ?? NSNull(), "visiblePixelSeconds": frames.visible.map { $0 as Any } ?? NSNull(), "fixtureInserted": passed, "insertedChars": field.string.count, "stopToInsertionSeconds": insertion.map { Double($0 - stop) / 1e9 } as Any? ?? NSNull(), "captureFrameIntervalSeconds": 1.0/60, "brightnessThreshold": "over 100 BGRA pixels with alpha>32 and RGB sum>180"]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            field.string = ""
            key(false)
            exit(audio == nil || passed ? EXIT_SUCCESS : EXIT_FAILURE)
        } catch {
            print("TIMING FAILED: \(error)")
            field.string = ""; key(false); exit(EXIT_FAILURE)
        }
    }
}
@main struct Main {
    @MainActor static func main() { let app = NSApplication.shared, delegate = Delegate(); app.delegate = delegate; app.run() }
}
