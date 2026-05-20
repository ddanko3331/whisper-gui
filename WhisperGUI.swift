import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Drop zone

final class DropZoneView: NSView {
    var onFileDropped: ((URL) -> Void)?

    private let hintLabel = NSTextField(labelWithString: "Drop audio or video here")
    private var isHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 8

        hintLabel.alignment = .center
        hintLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .secondaryLabelColor
        addSubview(hintLabel)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        hintLabel.frame = bounds.insetBy(dx: 12, dy: 12)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURL(sender) else { return [] }
        isHighlighted = true
        updateColors()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
        updateColors()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasFileURL(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        updateColors()
        guard let url = readFileURL(sender) else { return false }
        onFileDropped?(url)
        return true
    }

    private func hasFileURL(_ sender: NSDraggingInfo) -> Bool {
        readFileURL(sender) != nil
    }

    private func readFileURL(_ sender: NSDraggingInfo) -> URL? {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let u = urls.first {
            return u.isFileURL ? u : nil
        }
        return nil
    }

    private func updateColors() {
        if isHighlighted {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2
        } else {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
        }
    }
}

// MARK: - Settings

struct AppSettings: Codable {
    var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg"
    var sampleRate: Int = 16000
    var audioChannels: Int = 1
    var stripVideo: Bool = true
    var ffmpegLogLevel: String = "warning"
    var forceConvert: Bool = false

    var cliPath: String = "/opt/homebrew/bin/whisper-cli"
    var threads: Int = 4
    var language: String = "auto"
    var useGpu: Bool = false
    var translate: Bool = false
    var printProgress: Bool = true
    var noTimestamps: Bool = false
    var outputTxt: Bool = true
    var outputSrt: Bool = false
    var outputVtt: Bool = false
    var outputJson: Bool = false
    var initialPrompt: String = ""
    var durationMs: Int = 0
    var offsetMs: Int = 0
}

enum SettingsStore {
    static var path: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisper-gui/settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: path),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    static func save(_ settings: AppSettings) {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: path)
        }
    }
}

// MARK: - App

final class WhisperApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var audioField = NSTextField()
    private var modelField = NSTextField()
    private var dropZone = DropZoneView()
    private var logView = NSTextView()
    private var transcriptView = NSTextView()
    private var statusLabel = NSTextField(labelWithString: "")
    private var transcribeButton = NSButton()
    private var process: Process?
    private var readSource: DispatchSourceRead?
    private var convertedPath: String?

    private var settings = SettingsStore.load()

    // Advanced → Conversion
    private var ffmpegPathField = NSTextField()
    private var sampleRateField = NSTextField()
    private var channelsPopup = NSPopUpButton()
    private var stripVideoCheckbox = NSButton()
    private var ffmpegLogPopup = NSPopUpButton()
    private var forceConvertCheckbox = NSButton()

    // Advanced → Transcription
    private var cliPathField = NSTextField()
    private var threadsField = NSTextField()
    private var languagePopup = NSPopUpButton()
    private var gpuCheckbox = NSButton()
    private var translateCheckbox = NSButton()
    private var printProgressCheckbox = NSButton()
    private var noTimestampsCheckbox = NSButton()
    private var outputTxtCheckbox = NSButton()
    private var outputSrtCheckbox = NSButton()
    private var outputVttCheckbox = NSButton()
    private var outputJsonCheckbox = NSButton()
    private var promptField = NSTextField()
    private var durationField = NSTextField()
    private var offsetField = NSTextField()

    private let defaultModel = NSHomeDirectory() + "/whisper-medium.bin"
    private let defaultAudio = NSHomeDirectory() + "/input_ready.wav"

    /// whisper-cli only reads these; everything else goes through ffmpeg first.
    private static let whisperNativeExts: Set<String> = ["wav", "mp3", "flac", "ogg"]
    private static let convertExts: Set<String> = [
        "m4a", "qta", "mp4", "mov", "mkv", "webm", "aac", "caf", "m4v", "avi", "wmv",
    ]

    private func needsConversion(_ path: String) -> Bool {
        if settings.forceConvert { return true }
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.whisperNativeExts.contains(ext) { return false }
        if Self.convertExts.contains(ext) { return true }
        return true
    }

    private func collectSettingsFromUI() {
        settings.ffmpegPath = ffmpegPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.sampleRate = max(8000, Int(sampleRateField.stringValue) ?? 16000)
        settings.audioChannels = channelsPopup.indexOfSelectedItem == 1 ? 2 : 1
        settings.stripVideo = stripVideoCheckbox.state == .on
        settings.ffmpegLogLevel = ffmpegLogPopup.titleOfSelectedItem ?? "warning"
        settings.forceConvert = forceConvertCheckbox.state == .on

        settings.cliPath = cliPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.threads = max(1, min(32, Int(threadsField.stringValue) ?? 4))
        settings.language = languagePopup.titleOfSelectedItem ?? "auto"
        settings.useGpu = gpuCheckbox.state == .on
        settings.translate = translateCheckbox.state == .on
        settings.printProgress = printProgressCheckbox.state == .on
        settings.noTimestamps = noTimestampsCheckbox.state == .on
        settings.outputTxt = outputTxtCheckbox.state == .on
        settings.outputSrt = outputSrtCheckbox.state == .on
        settings.outputVtt = outputVttCheckbox.state == .on
        settings.outputJson = outputJsonCheckbox.state == .on
        settings.initialPrompt = promptField.stringValue
        settings.durationMs = max(0, Int(durationField.stringValue) ?? 0)
        settings.offsetMs = max(0, Int(offsetField.stringValue) ?? 0)
        SettingsStore.save(settings)
    }

    private func applySettingsToUI() {
        ffmpegPathField.stringValue = settings.ffmpegPath
        sampleRateField.stringValue = String(settings.sampleRate)
        channelsPopup.selectItem(at: settings.audioChannels == 2 ? 1 : 0)
        stripVideoCheckbox.state = settings.stripVideo ? .on : .off
        if let i = ["error", "warning", "info", "verbose"].firstIndex(of: settings.ffmpegLogLevel) {
            ffmpegLogPopup.selectItem(at: i)
        }
        forceConvertCheckbox.state = settings.forceConvert ? .on : .off

        cliPathField.stringValue = settings.cliPath
        threadsField.stringValue = String(settings.threads)
        if let i = ["auto", "en", "ru", "de", "fr", "es", "it", "uk", "zh", "ja"].firstIndex(of: settings.language) {
            languagePopup.selectItem(at: i)
        }
        gpuCheckbox.state = settings.useGpu ? .on : .off
        translateCheckbox.state = settings.translate ? .on : .off
        printProgressCheckbox.state = settings.printProgress ? .on : .off
        noTimestampsCheckbox.state = settings.noTimestamps ? .on : .off
        outputTxtCheckbox.state = settings.outputTxt ? .on : .off
        outputSrtCheckbox.state = settings.outputSrt ? .on : .off
        outputVttCheckbox.state = settings.outputVtt ? .on : .off
        outputJsonCheckbox.state = settings.outputJson ? .on : .off
        promptField.stringValue = settings.initialPrompt
        durationField.stringValue = settings.durationMs > 0 ? String(settings.durationMs) : ""
        offsetField.stringValue = settings.offsetMs > 0 ? String(settings.offsetMs) : ""
    }

    @objc private func saveSettingsClicked() {
        collectSettingsFromUI()
        statusLabel.stringValue = "Settings saved."
    }

    /// Modern macOS (Monterey+) and legacy Voice Memos storage.
    private static let voiceMemosDirectories: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings"),
    ]

    private func voiceMemosFolder() -> URL? {
        for url in Self.voiceMemosDirectories {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return Self.voiceMemosDirectories.first
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        audioField.stringValue = FileManager.default.fileExists(atPath: defaultAudio) ? defaultAudio : ""
        modelField.stringValue = defaultModel
        statusLabel.stringValue = "Drop any file — converts via ffmpeg when needed."
        statusLabel.lineBreakMode = .byTruncatingTail
        dropZone.onFileDropped = { [weak self] url in self?.handleDroppedFile(url) }

        let mainTab = buildMainTab()
        let advancedTab = buildAdvancedTab()

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let mainItem = NSTabViewItem(identifier: "main")
        mainItem.label = "Main"
        mainItem.view = mainTab
        tabs.addTabViewItem(mainItem)
        let advItem = NSTabViewItem(identifier: "advanced")
        advItem.label = "Advanced"
        advItem.view = advancedTab
        tabs.addTabViewItem(advItem)

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper"
        window.minSize = NSSize(width: 520, height: 420)
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.contentView = root
        window.center()
    }

    private func buildMainTab() -> NSView {
        transcribeButton = NSButton(title: "Transcribe", target: self, action: #selector(runTranscribe))
        transcribeButton.bezelStyle = .rounded
        let openFolder = NSButton(title: "Open folder", target: self, action: #selector(openFolder))
        let pickAudio = NSButton(title: "Choose…", target: self, action: #selector(pickAudio))
        let pickMemos = NSButton(title: "Voice Memos", target: self, action: #selector(pickVoiceMemos))
        let pickModel = NSButton(title: "Choose…", target: self, action: #selector(pickModel))

        logView.isEditable = false
        logView.isRichText = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true

        transcriptView.isEditable = false
        transcriptView.isRichText = false
        transcriptView.font = NSFont.systemFont(ofSize: 14)
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true

        let logScroll = makeScrollView(document: logView)
        let txScroll = makeScrollView(document: transcriptView)

        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(wrapPanel(title: "Log", scroll: logScroll))
        split.addArrangedSubview(wrapPanel(title: "Transcript", scroll: txScroll))

        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false

        let topStack = NSStackView()
        topStack.orientation = .vertical
        topStack.alignment = .width
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false
        audioField.translatesAutoresizingMaskIntoConstraints = false
        modelField.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        topStack.addArrangedSubview(dropZone)
        topStack.addArrangedSubview(makeLabeledRow(label: "Audio", field: audioField, buttons: [pickAudio, pickMemos]))
        topStack.addArrangedSubview(makeLabeledRow(label: "Model", field: modelField, buttons: [pickModel]))
        topStack.addArrangedSubview(makeButtonRow([transcribeButton, openFolder]))
        topStack.addArrangedSubview(statusLabel)

        tab.addSubview(topStack)
        tab.addSubview(split)
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: tab.topAnchor, constant: 8),
            topStack.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 12),
            topStack.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -12),
            split.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -8),
            dropZone.heightAnchor.constraint(equalToConstant: 56),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        DispatchQueue.main.async { split.setPosition(220, ofDividerAt: 0) }
        return tab
    }

    private func buildAdvancedTab() -> NSView {
        configureSettingsControls()
        applySettingsToUI()

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .width
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        form.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        form.addArrangedSubview(sectionHeader("Conversion"))
        form.addArrangedSubview(formRow("ffmpeg path", ffmpegPathField, browse: #selector(pickFfmpeg)))
        form.addArrangedSubview(formRow("Sample rate", sampleRateField))
        form.addArrangedSubview(formRow("Channels", channelsPopup))
        form.addArrangedSubview(formRow("Log level", ffmpegLogPopup))
        form.addArrangedSubview(indentedCheck(stripVideoCheckbox))
        form.addArrangedSubview(indentedCheck(forceConvertCheckbox))

        form.addArrangedSubview(sectionSeparator())

        form.addArrangedSubview(sectionHeader("Transcription"))
        form.addArrangedSubview(formRow("whisper-cli path", cliPathField, browse: #selector(pickCli)))
        form.addArrangedSubview(formRow("Threads", threadsField, width: 72))
        form.addArrangedSubview(formRow("Language", languagePopup, width: 120))
        form.addArrangedSubview(indentedCheck(gpuCheckbox))
        form.addArrangedSubview(indentedCheck(translateCheckbox))
        form.addArrangedSubview(indentedCheck(printProgressCheckbox))
        form.addArrangedSubview(indentedCheck(noTimestampsCheckbox))
        form.addArrangedSubview(formRow("Save files", outputFormatsRow()))
        form.addArrangedSubview(formRow("Initial prompt", promptField))
        form.addArrangedSubview(formRow("Duration (ms)", durationField, width: 100))
        form.addArrangedSubview(formRow("Start offset (ms)", offsetField, width: 100))

        let saveBtn = NSButton(title: "Save settings", target: self, action: #selector(saveSettingsClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.translatesAutoresizingMaskIntoConstraints = false

        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(form)
        tab.addSubview(saveBtn)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: tab.topAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -20),
            form.bottomAnchor.constraint(lessThanOrEqualTo: saveBtn.topAnchor, constant: -16),
            saveBtn.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -20),
            saveBtn.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -14),
        ])
        return tab
    }

    private func configureSettingsControls() {
        [ffmpegPathField, cliPathField, sampleRateField, threadsField, promptField,
         durationField, offsetField].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        channelsPopup.removeAllItems()
        channelsPopup.addItems(withTitles: ["Mono (1)", "Stereo (2)"])
        ffmpegLogPopup.removeAllItems()
        ffmpegLogPopup.addItems(withTitles: ["error", "warning", "info", "verbose"])
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: ["auto", "en", "ru", "de", "fr", "es", "it", "uk", "zh", "ja"])
        [channelsPopup, ffmpegLogPopup, languagePopup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        stripVideoCheckbox = NSButton(checkboxWithTitle: "Strip video (keep audio only)", target: nil, action: nil)
        forceConvertCheckbox = NSButton(checkboxWithTitle: "Always convert (even .wav / .mp3)", target: nil, action: nil)
        gpuCheckbox = NSButton(checkboxWithTitle: "Use GPU (Metal)", target: nil, action: nil)
        translateCheckbox = NSButton(checkboxWithTitle: "Translate to English", target: nil, action: nil)
        printProgressCheckbox = NSButton(checkboxWithTitle: "Print progress", target: nil, action: nil)
        noTimestampsCheckbox = NSButton(checkboxWithTitle: "Plain text (no timestamps)", target: nil, action: nil)
        outputTxtCheckbox = NSButton(checkboxWithTitle: ".txt", target: nil, action: nil)
        outputSrtCheckbox = NSButton(checkboxWithTitle: ".srt", target: nil, action: nil)
        outputVttCheckbox = NSButton(checkboxWithTitle: ".vtt", target: nil, action: nil)
        outputJsonCheckbox = NSButton(checkboxWithTitle: ".json", target: nil, action: nil)

        promptField.placeholderString = "Names, jargon, context…"
        durationField.placeholderString = "0 = full file"
        offsetField.placeholderString = "0 = from start"
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func sectionSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    private func formRow(_ label: String, _ control: NSView, browse: Selector? = nil, width: CGFloat? = nil) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 148).isActive = true
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        control.translatesAutoresizingMaskIntoConstraints = false
        if let width {
            control.widthAnchor.constraint(equalToConstant: width).isActive = true
            control.setContentHuggingPriority(.required, for: .horizontal)
        } else {
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        var views: [NSView] = [title, control]
        if let browse {
            let btn = NSButton(title: "Browse…", target: self, action: browse)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.setContentHuggingPriority(.required, for: .horizontal)
            views.append(btn)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        return row
    }

    private func indentedCheck(_ box: NSButton) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 148).isActive = true
        box.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [spacer, box])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func outputFormatsRow() -> NSStackView {
        let row = NSStackView(views: [outputTxtCheckbox, outputSrtCheckbox, outputVttCheckbox, outputJsonCheckbox])
        row.orientation = .horizontal
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        return formRow("Save files", row)
    }

    @objc private func pickFfmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { ffmpegPathField.stringValue = url.path }
    }

    @objc private func pickCli() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { cliPathField.stringValue = url.path }
    }

    private func makeScrollView(document: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func wrapPanel(title: String, scroll: NSScrollView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)
        panel.addSubview(scroll)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: panel.topAnchor),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return panel
    }

    private func makeLabeledRow(label: String, field: NSView, buttons: [NSView]) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [title, field] + buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeButtonRow(_ buttons: [NSView]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - Drop & convert

    private func handleDroppedFile(_ url: URL) {
        prepareAudio(from: url, autoTranscribe: false)
    }

    private func prepareAudio(from url: URL, autoTranscribe: Bool) {
        collectSettingsFromUI()
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            alert("File not found:\n\(path)")
            return
        }

        transcribeButton.isEnabled = false
        statusLabel.stringValue = "Preparing…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let ready = try self.resolveAudioPath(path)
                DispatchQueue.main.async {
                    self.audioField.stringValue = ready
                    self.transcribeButton.isEnabled = true
                    self.statusLabel.stringValue = "Ready — click Transcribe or drop another file."
                    if autoTranscribe {
                        self.runTranscribe()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.transcribeButton.isEnabled = true
                    self.statusLabel.stringValue = "Conversion failed."
                    self.alert(error.localizedDescription)
                }
            }
        }
    }

    /// Writable folder — cannot save next to Voice Memos (macOS blocks writes there).
    private func convertedOutputDirectory() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisper-gui/converted", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func convertedOutputPath(for sourcePath: String) throws -> String {
        let dir = try convertedOutputDirectory()
        let raw = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let safe = raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .map(String.init).joined()
        let base = safe.isEmpty ? "audio" : String(safe.prefix(80))
        var candidate = dir.appendingPathComponent("\(base)_whisper.wav")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_whisper-\(n).wav")
            n += 1
        }
        return candidate.path
    }

    private func resolveAudioPath(_ path: String) throws -> String {
        if !needsConversion(path) {
            DispatchQueue.main.async { [weak self] in
                self?.appendLog("Using native format: \((path as NSString).lastPathComponent)\n")
            }
            convertedPath = nil
            return path
        }

        let ffmpeg = settings.ffmpegPath
        guard FileManager.default.fileExists(atPath: ffmpeg) else {
            throw NSError(
                domain: "WhisperGUI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found at \(ffmpeg)\n\nInstall: brew install ffmpeg"]
            )
        }

        guard FileManager.default.isReadableFile(atPath: path) else {
            throw NSError(
                domain: "WhisperGUI",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Cannot read input file:\n\(path)"]
            )
        }

        let outPath = try convertedOutputPath(for: path)

        DispatchQueue.main.async { [weak self] in
            self?.appendLog("Converting with ffmpeg…\n  in:  \(path)\n  out: \(outPath)\n\n")
        }

        var ffArgs = [
            "-nostdin", "-hide_banner", "-loglevel", settings.ffmpegLogLevel,
            "-y", "-i", path,
        ]
        if settings.stripVideo { ffArgs.append("-vn") }
        ffArgs += ["-ar", String(settings.sampleRate), "-ac", String(settings.audioChannels),
                   "-c:a", "pcm_s16le", outPath]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ffArgs
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()

        let errOut = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        DispatchQueue.main.async { [weak self] in
            if !errOut.isEmpty { self?.appendLog(errOut + "\n") }
        }

        guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: outPath) else {
            let tail = errOut.split(separator: "\n").suffix(8).joined(separator: "\n")
            var msg = "ffmpeg failed (exit \(proc.terminationStatus))."
            if !tail.isEmpty { msg += "\n\n\(tail)" }
            if path.contains("VoiceMemos") {
                msg += "\n\n(Voice Memos files are converted to Application Support, not the Recordings folder.)"
            }
            throw NSError(domain: "WhisperGUI", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        convertedPath = outPath
        DispatchQueue.main.async { [weak self] in
            self?.appendLog("Conversion done.\n\n")
        }
        return outPath
    }

    // MARK: - Pickers

    @objc private func pickAudio() {
        showAudioPicker(directory: nil, prompt: "Choose audio or video")
    }

    @objc private func pickVoiceMemos() {
        guard let folder = voiceMemosFolder() else { return }
        let exists = FileManager.default.fileExists(atPath: folder.path)
        if !exists {
            alert(
                """
                Voice Memos folder not found yet.

                Export from the Voice Memos app:
                • Select a memo → Share (⋯) → Save to Downloads
                • Or drag the memo into this app’s drop zone

                Expected folder (may appear after your first recording):
                \(folder.path)
                """
            )
            return
        }
        let count = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
            ["m4a", "qta", "wav", "caf"].contains(($0 as NSString).pathExtension.lowercased())
        }.count) ?? 0
        if count == 0 {
            appendLog("Voice Memos folder is empty or still syncing from iCloud.\n")
        }
        showAudioPicker(directory: folder, prompt: "Choose a Voice Memo (.m4a)")
    }

    private func showAudioPicker(directory: URL?, prompt: String) {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .audio, .movie, .mpeg4Movie, .video, .wav, .mp3, .mpeg4Audio,
            UTType(filenameExtension: "m4a"), UTType(filenameExtension: "qta"),
            UTType(filenameExtension: "mkv"),
        ].compactMap { $0 }
        if let directory {
            panel.directoryURL = directory
        }
        if panel.runModal() == .OK, let url = panel.url {
            prepareAudio(from: url, autoTranscribe: false)
        }
    }

    @objc private func pickModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK, let url = panel.url {
            modelField.stringValue = url.path
        }
    }

    @objc private func openFolder() {
        let path = (audioField.stringValue as NSString).deletingLastPathComponent
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Transcribe

    @objc private func runTranscribe() {
        collectSettingsFromUI()
        let audio = audioField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cli = settings.cliPath

        guard !audio.isEmpty else {
            alert("Drop a file or click Choose… first.")
            return
        }
        guard FileManager.default.fileExists(atPath: audio) else {
            alert("Audio file not found:\n\(audio)")
            return
        }
        guard FileManager.default.fileExists(atPath: cli) else {
            alert("whisper-cli not found at:\n\(cli)\n\nInstall: brew install whisper-cpp")
            return
        }
        guard FileManager.default.fileExists(atPath: model) else {
            alert("Model not found:\n\(model)")
            return
        }

        stopProcess()
        transcribeButton.isEnabled = false
        statusLabel.stringValue = "Preparing…"

        let sourceURL = URL(fileURLWithPath: audio)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                let ready = try self.resolveAudioPath(audio)
                DispatchQueue.main.async {
                    self.audioField.stringValue = ready
                    self.startWhisper(audio: ready, model: model)
                }
            } catch {
                DispatchQueue.main.async {
                    self.transcribeButton.isEnabled = true
                    self.statusLabel.stringValue = "Preparation failed."
                    self.alert(error.localizedDescription)
                }
            }
        }
    }

    private func startWhisper(audio: String, model: String) {
        transcriptView.string = ""
        transcribeButton.isEnabled = false
        statusLabel.stringValue = "Transcribing…"

        let stem = (audio as NSString).deletingPathExtension
        let cli = settings.cliPath
        var args = [cli, "-m", model, "-f", audio, "-t", String(settings.threads), "-l", settings.language]
        if !settings.useGpu { args.insert("-ng", at: 1) }
        if settings.translate { args.append("-tr") }
        if settings.printProgress { args.append("-pp") }
        if settings.noTimestamps { args.append("-nt") }
        if settings.outputTxt { args.append("-otxt") }
        if settings.outputSrt { args.append("-osrt") }
        if settings.outputVtt { args.append("-ovtt") }
        if settings.outputJson { args.append("-oj") }
        if settings.durationMs > 0 { args += ["-d", String(settings.durationMs)] }
        if settings.offsetMs > 0 { args += ["-ot", String(settings.offsetMs)] }
        let prompt = settings.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { args += ["--prompt", prompt] }
        args += ["-of", stem]

        appendLog("\n--- whisper ---\n$ \(args.joined(separator: " "))\n\n")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.onFinished(exitCode: p.terminationStatus, audioStem: stem)
            }
        }

        do {
            try proc.run()
            process = proc
            let fd = pipe.fileHandleForReading.fileDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
            readSource = source
            source.setEventHandler { [weak self] in
                let data = pipe.fileHandleForReading.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { self?.appendLog(text) }
            }
            source.setCancelHandler { pipe.fileHandleForReading.closeFile() }
            source.resume()
        } catch {
            transcribeButton.isEnabled = true
            alert("Failed to start whisper-cli:\n\(error.localizedDescription)")
        }
    }

    private func stopProcess() {
        readSource?.cancel()
        readSource = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
    }

    private func onFinished(exitCode: Int32, audioStem: String) {
        readSource?.cancel()
        readSource = nil
        process = nil
        transcribeButton.isEnabled = true

        let candidates = [
            settings.outputTxt ? audioStem + ".txt" : nil,
            settings.outputSrt ? audioStem + ".srt" : nil,
            settings.outputVtt ? audioStem + ".vtt" : nil,
            settings.outputJson ? audioStem + ".json" : nil,
        ].compactMap { $0 }
        if let found = candidates.first(where: { loadTranscriptText(txtPath: $0) != nil }),
           let text = loadTranscriptText(txtPath: found) {
            transcriptView.string = text
            statusLabel.stringValue = "Done — saved \(found)"
        } else if exitCode == 0, let fallback = extractTranscriptFromLog() {
            transcriptView.string = fallback
            statusLabel.stringValue = "Done (from log; .txt not found at expected path)."
        } else if exitCode == 0 {
            statusLabel.stringValue = "Done (check log for output)."
        } else {
            statusLabel.stringValue = "Failed (exit \(exitCode))."
            var msg = "whisper-cli exited with code \(exitCode)."
            if (exitCode == 139 || exitCode == 11) && settings.useGpu {
                msg += "\n\nTry turning off “Use GPU”."
            }
            alert(msg)
        }
    }

    private func loadTranscriptText(txtPath: String) -> String? {
        if FileManager.default.fileExists(atPath: txtPath),
           let text = try? String(contentsOfFile: txtPath, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }

    private func extractTranscriptFromLog() -> String? {
        let log = logView.string
        var lines: [String] = []
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("whisper_") || s.hasPrefix("ggml_") || s.hasPrefix("load_")
                || s.hasPrefix("[") && s.contains(" --> ") || s.hasPrefix("$ ")
                || s.hasPrefix("---") || s.hasPrefix("Converting") || s.hasPrefix("  in:")
                || s.hasPrefix("  out:") || s.hasPrefix("system_info") {
                continue
            }
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.count > 2 { lines.append(t) }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private func appendLog(_ text: String) {
        logView.string += text
        logView.scrollToEndOfDocument(nil)
    }

    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = "Whisper"
        a.informativeText = message
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = WhisperApp()
app.delegate = delegate
app.run()
