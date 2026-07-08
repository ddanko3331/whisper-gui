import AppKit
import Foundation
import UniformTypeIdentifiers
import AVFoundation
import Contacts

// MARK: - Flipped Clip View

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool {
        return true
    }
}

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

    var obsidianVaultPath: String = ""
    var obsidianSaveDirectly: Bool = false
    var obsidianFolder: String = "Transcriptions"
    
    var diarizeEnabled: Bool = false
    var diarizeThreshold: Double = 0.65
    var diarizeSpeakers: Int = 0
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
    private var progressBar: NSProgressIndicator?
    private var progressLabel = NSTextField(labelWithString: "0%")
    private var progressStack: NSStackView?
    private var process: Process?
    private var readSource: DispatchSourceRead?
    private var convertedPath: String?
    private var originalSourcePath: String?
    private var customNameField = NSTextField()
    private var noteNameField = NSTextField()
    private var tagOptions = ["meeting", "conference", "bank", "lecture", "interview", "podcast"]
    private var tagsField = NSTextField()

    // Browser tab state & controls
    private var browserFiles: [URL] = []
    private var selectedBrowserDir: URL?
    private var browserListView = NSStackView()
    private var browserTextView = NSTextView()
    private var browserPathLabel = NSTextField(labelWithString: "")
    private var browserDeleteButton = NSButton()
    private var browserOpenButton = NSButton()
    private var browserCopyButton = NSButton()
    private var browserShareButton = NSButton()
    private var browserRenameSpkButton = NSButton()
    private var previousActiveRange: NSRange?
    private var browserSelectedURL: URL?
    // Main Audio Preview State & Controls
    private var previewPlayer: AVAudioPlayer?
    private var previewTimer: Timer?
    private var previewPlayButton = NSButton()
    private var previewSlider = NSSlider()
    private var previewTimeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private var previewPlayerRow: NSStackView?

    // Browser Audio Player State & Controls
    private var browserPlayer: AVAudioPlayer?
    private var browserTimer: Timer?
    private var browserPlayButton = NSButton()
    private var browserSlider = NSSlider()
    private var browserTimeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private var browserPlayerRow: NSStackView?
    private var browserAudioURL: URL?
    private var timestampRanges: [(start: Double, end: Double, range: NSRange)] = []
    
    // Speaker Diarization Properties
    private var diarizeCheckbox = NSButton()
    private var registeredSpeakersLabel = NSTextField(labelWithString: "None registered")
    private var isTranscribing = false
    private var transcribeTimer: Timer?
    private var transcribeSpinnerIndex = 0
    
    // Register Voice Window State
    private var registerVoiceWindow: NSWindow?
    private var registerVoiceCombo = NSComboBox()
    private var registerVoiceFilePath = NSTextField()
    private var registerVoiceStatus = NSTextField(labelWithString: "")
    private var registerVoiceSubmitBtn = NSButton()

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

    // Advanced → Obsidian
    private var obsidianVaultPathField = NSTextField()
    private var obsidianSaveCheckbox = NSButton()
    private var obsidianFolderField = NSTextField()

    // Advanced → Diarization
    private var diarizeThresholdField = NSTextField()
    private var diarizeSpeakersField = NSTextField()

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

        settings.obsidianVaultPath = obsidianVaultPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.obsidianSaveDirectly = obsidianSaveCheckbox.state == .on
        settings.obsidianFolder = obsidianFolderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.obsidianFolder.isEmpty {
            settings.obsidianFolder = "Transcriptions"
        }
        
        settings.diarizeThreshold = Double(diarizeThresholdField.stringValue) ?? 0.65
        settings.diarizeSpeakers = max(0, Int(diarizeSpeakersField.stringValue) ?? 0)

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

        obsidianVaultPathField.stringValue = settings.obsidianVaultPath
        obsidianSaveCheckbox.state = settings.obsidianSaveDirectly ? .on : .off
        obsidianFolderField.stringValue = settings.obsidianFolder
        
        diarizeThresholdField.stringValue = String(settings.diarizeThreshold)
        diarizeSpeakersField.stringValue = String(settings.diarizeSpeakers)
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
        setupMenuBar()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()
        
        // 1. Application Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        
        let appName = "Whisper GUI"
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesProvider = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(NSMenuItem.separator())
        
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        // 2. Edit Menu (Crucial for copy, paste, select all)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSTextView.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        audioField.stringValue = FileManager.default.fileExists(atPath: defaultAudio) ? defaultAudio : ""
        modelField.stringValue = defaultModel
        statusLabel.stringValue = "Drop any file — converts via ffmpeg when needed."
        statusLabel.lineBreakMode = .byTruncatingTail
        dropZone.onFileDropped = { [weak self] url in self?.handleDroppedFile(url) }

        let mainTab = buildMainTab()
        let advancedTab = buildAdvancedTab()
        let browserTab = buildBrowserTab()

        autoDiscoverObsidianVault()

        let tabs = NSTabView()
        tabs.delegate = self
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let mainItem = NSTabViewItem(identifier: "main")
        mainItem.label = "Main"
        mainItem.view = mainTab
        tabs.addTabViewItem(mainItem)
        let advItem = NSTabViewItem(identifier: "advanced")
        advItem.label = "Advanced"
        advItem.view = advancedTab
        tabs.addTabViewItem(advItem)
        let browserItem = NSTabViewItem(identifier: "browser")
        browserItem.label = "Browser"
        browserItem.view = browserTab
        tabs.addTabViewItem(browserItem)

        let root = NSView()
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
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "Whisper"
        window.minSize = NSSize(width: 520, height: 420)
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.contentView = root
        window.center()
    }

    private func buildMainTab() -> NSView {
        transcribeButton = NSButton(title: "  Transcribe", target: self, action: #selector(runTranscribe))
        transcribeButton.bezelStyle = .regularSquare
        transcribeButton.isBordered = false
        transcribeButton.wantsLayer = true
        transcribeButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        transcribeButton.layer?.cornerRadius = 6
        
        let pstyle = NSMutableParagraphStyle()
        pstyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .paragraphStyle: pstyle
        ]
        transcribeButton.attributedTitle = NSAttributedString(string: "  Transcribe", attributes: attrs)
        
        if #available(macOS 11.0, *) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            transcribeButton.image = NSImage(systemSymbolName: "waveform.path.badge.plus", accessibilityDescription: "Transcribe")?.withSymbolConfiguration(config)
            transcribeButton.imagePosition = .imageLeft
        }
        transcribeButton.translatesAutoresizingMaskIntoConstraints = false
        transcribeButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        transcribeButton.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let openFolder = NSButton(title: "Open folder", target: self, action: #selector(openFolder))
        openFolder.bezelStyle = .rounded
        openFolder.translatesAutoresizingMaskIntoConstraints = false
        openFolder.heightAnchor.constraint(equalToConstant: 32).isActive = true
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
        logView.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1.0)
        logView.textColor = NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)

        transcriptView.isEditable = false
        transcriptView.isRichText = false
        transcriptView.font = NSFont.systemFont(ofSize: 14)
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.backgroundColor = NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)
        transcriptView.textColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)

        let logScroll = makeScrollView(document: logView)
        logScroll.drawsBackground = true
        logScroll.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1.0)
        
        let txScroll = makeScrollView(document: transcriptView)
        txScroll.drawsBackground = true
        txScroll.backgroundColor = NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)

        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(wrapPanel(title: "Log", scroll: logScroll))
        split.addArrangedSubview(wrapPanel(title: "Transcript", scroll: txScroll))

        let tab = NSView()

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

        // Setup Main Tab Audio Preview Player UI
        previewPlayButton.title = "▶"
        previewPlayButton.bezelStyle = .rounded
        previewPlayButton.isEnabled = false
        previewPlayButton.target = self
        previewPlayButton.action = #selector(playPausePreviewClicked)
        previewPlayButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        previewSlider.minValue = 0
        previewSlider.maxValue = 1
        previewSlider.doubleValue = 0
        previewSlider.target = self
        previewSlider.action = #selector(previewSliderDragged)
        previewSlider.isEnabled = false

        previewTimeLabel.isEditable = false
        previewTimeLabel.isBordered = false
        previewTimeLabel.backgroundColor = .clear
        previewTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        previewTimeLabel.textColor = .secondaryLabelColor
        previewTimeLabel.alignment = .right
        previewTimeLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let playerInnerStack = NSStackView(views: [previewPlayButton, previewSlider, previewTimeLabel])
        playerInnerStack.orientation = .horizontal
        playerInnerStack.spacing = 8
        playerInnerStack.alignment = .centerY
        playerInnerStack.distribution = .fill
        playerInnerStack.translatesAutoresizingMaskIntoConstraints = false

        let playerRow = makeLabeledRow(label: "Preview", field: playerInnerStack, buttons: [])
        previewPlayerRow = playerRow
        playerRow.isHidden = false
        topStack.addArrangedSubview(playerRow)

        topStack.addArrangedSubview(makeLabeledRow(label: "Model", field: modelField, buttons: [pickModel]))
        
        customNameField.translatesAutoresizingMaskIntoConstraints = false
        customNameField.placeholderString = "Optional custom output filename"
        
        noteNameField.translatesAutoresizingMaskIntoConstraints = false
        noteNameField.placeholderString = "Optional note name for header"
        
        tagsField.translatesAutoresizingMaskIntoConstraints = false
        tagsField.placeholderString = "e.g. meeting, podcast (or choose from list)"
        tagsField.delegate = self
        
        let chooseTagsBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseTagsClicked(_:)))
        chooseTagsBtn.translatesAutoresizingMaskIntoConstraints = false
        
        let importTagsBtn = NSButton(title: "Import…", target: self, action: #selector(importObsidianTagsClicked))
        importTagsBtn.translatesAutoresizingMaskIntoConstraints = false
        
        topStack.addArrangedSubview(makeLabeledRow(label: "Save Name", field: customNameField, buttons: []))
        topStack.addArrangedSubview(makeLabeledRow(label: "Note Name", field: noteNameField, buttons: []))
        topStack.addArrangedSubview(makeLabeledRow(label: "Tags", field: tagsField, buttons: [chooseTagsBtn, importTagsBtn]))
        
        // Setup Speakers Row
        diarizeCheckbox = NSButton(checkboxWithTitle: "👥 Enable Local Diarization (Speaker Recognition)", target: self, action: #selector(diarizeToggled))
        diarizeCheckbox.state = settings.diarizeEnabled ? .on : .off
        diarizeCheckbox.translatesAutoresizingMaskIntoConstraints = false
        
        let registerVoiceBtn = NSButton(title: "Register Voice…", target: self, action: #selector(registerVoiceClicked))
        registerVoiceBtn.bezelStyle = .rounded
        registerVoiceBtn.translatesAutoresizingMaskIntoConstraints = false
        
        registeredSpeakersLabel.isEditable = false
        registeredSpeakersLabel.isBordered = false
        registeredSpeakersLabel.backgroundColor = .clear
        registeredSpeakersLabel.textColor = .secondaryLabelColor
        registeredSpeakersLabel.font = NSFont.systemFont(ofSize: 11)
        registeredSpeakersLabel.translatesAutoresizingMaskIntoConstraints = false
        
        refreshSpeakersList()
        
        let speakersInnerStack = NSStackView(views: [diarizeCheckbox, registerVoiceBtn, registeredSpeakersLabel])
        speakersInnerStack.orientation = .horizontal
        speakersInnerStack.spacing = 12
        speakersInnerStack.alignment = .centerY
        speakersInnerStack.distribution = .fill
        speakersInnerStack.translatesAutoresizingMaskIntoConstraints = false
        
        topStack.addArrangedSubview(makeLabeledRow(label: "Speakers", field: speakersInnerStack, buttons: []))
        
        topStack.addArrangedSubview(makeButtonRow([transcribeButton, openFolder]))
        
        let progressIndicator = NSProgressIndicator()
        progressIndicator.isIndeterminate = false
        progressIndicator.style = .bar
        progressIndicator.minValue = 0.0
        progressIndicator.maxValue = 100.0
        progressIndicator.doubleValue = 0.0
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        self.progressBar = progressIndicator
        
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.isEditable = false
        progressLabel.isBordered = false
        progressLabel.backgroundColor = .clear
        progressLabel.stringValue = "0%"
        progressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progressLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        progressLabel.alignment = .right
        
        let pStack = NSStackView(views: [progressIndicator, progressLabel])
        pStack.orientation = .horizontal
        pStack.spacing = 8
        pStack.alignment = .centerY
        pStack.distribution = .fill
        pStack.translatesAutoresizingMaskIntoConstraints = false
        pStack.isHidden = true
        self.progressStack = pStack
        topStack.addArrangedSubview(pStack)
        
        let buildLabel = NSTextField(labelWithString: "Version 2.1.0 (Build 2026.0529)")
        buildLabel.textColor = .secondaryLabelColor
        buildLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        buildLabel.alignment = .right
        buildLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let bottomBarStack = NSStackView(views: [statusLabel, buildLabel])
        bottomBarStack.orientation = .horizontal
        bottomBarStack.distribution = .fill
        bottomBarStack.alignment = .centerY
        bottomBarStack.spacing = 8
        bottomBarStack.translatesAutoresizingMaskIntoConstraints = false
        
        topStack.addArrangedSubview(bottomBarStack)

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
        
        let updateBtn = NSButton(title: "Check for Updates", target: self, action: #selector(checkWhisperUpdate))
        updateBtn.bezelStyle = .rounded
        form.addArrangedSubview(formRow("whisper-cpp", updateBtn))
        
        let sherpaUpdateBtn = NSButton(title: "Check for Updates", target: self, action: #selector(checkSherpaUpdate))
        sherpaUpdateBtn.bezelStyle = .rounded
        form.addArrangedSubview(formRow("sherpa-onnx", sherpaUpdateBtn))

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

        form.addArrangedSubview(sectionSeparator())

        form.addArrangedSubview(sectionHeader("Obsidian Integration"))
        form.addArrangedSubview(formRow("Obsidian Vault", obsidianVaultPathField, browse: #selector(pickObsidianVault)))
        form.addArrangedSubview(formRow("Vault folder", obsidianFolderField, width: 200))
        form.addArrangedSubview(indentedCheck(obsidianSaveCheckbox))

        form.addArrangedSubview(sectionSeparator())

        form.addArrangedSubview(sectionHeader("Speaker Diarization"))
        form.addArrangedSubview(formRow("Match threshold", diarizeThresholdField, width: 80))
        form.addArrangedSubview(formRow("Expected speakers", diarizeSpeakersField, width: 80))

        form.addArrangedSubview(sectionSeparator())

        form.addArrangedSubview(sectionHeader("System & Dependencies"))
        
        let appVersionLabel = NSTextField(labelWithString: "1.2.0 (Active)")
        appVersionLabel.font = NSFont.systemFont(ofSize: 13)
        appVersionLabel.isEditable = false
        appVersionLabel.isBordered = false
        appVersionLabel.backgroundColor = .clear
        form.addArrangedSubview(formRow("App version", appVersionLabel))

        let checkDepBtn = NSButton(title: "Check Dependencies", target: self, action: #selector(checkDependenciesClicked))
        checkDepBtn.bezelStyle = .rounded
        form.addArrangedSubview(formRow("System check", checkDepBtn))

        let readmeScrollView = NSScrollView()
        readmeScrollView.translatesAutoresizingMaskIntoConstraints = false
        readmeScrollView.heightAnchor.constraint(equalToConstant: 120).isActive = true
        readmeScrollView.hasVerticalScroller = true
        readmeScrollView.borderType = .bezelBorder

        let readmeTextView = NSTextView()
        readmeTextView.isEditable = false
        readmeTextView.isSelectable = true
        readmeTextView.font = NSFont.userFixedPitchFont(ofSize: 11)
        readmeTextView.textColor = .labelColor
        readmeTextView.drawsBackground = false
        readmeTextView.string = """
=== WHISPER GUI - README & RELEASE NOTES ===

Whisper GUI is a premium client for whisper.cpp.

RELEASE NOTES (v1.2.0):
- Added asynchronous "Check Dependencies" diagnostics.
- Added premium transcribing button pulsing glow animation.
- Resolved speaker recognition pipe deadlock on long audios.
- Resolved argument conflicts between plain-text and diarization.
- Enabled real-time stdout/stderr log streaming.

REQUIREMENTS:
- whisper-cli (brew install whisper-cpp)
- ffmpeg (brew install ffmpeg)
- python3 (with wave, json, math, struct)
"""
        readmeScrollView.documentView = readmeTextView
        form.addArrangedSubview(formRow("Docs & Notes", readmeScrollView))

        let saveBtn = NSButton(title: "Save settings", target: self, action: #selector(saveSettingsClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        let clipView = FlippedClipView()
        scrollView.contentView = clipView
        scrollView.documentView = form
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let tab = NSView()
        tab.addSubview(scrollView)
        tab.addSubview(saveBtn)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: tab.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tab.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: saveBtn.topAnchor, constant: -12),
            
            saveBtn.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -20),
            saveBtn.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -14),
            
            form.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor)
        ])
        
        let bottomConst = form.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor)
        bottomConst.priority = .defaultLow
        bottomConst.isActive = true
        return tab
    }

    private func configureSettingsControls() {
        [ffmpegPathField, cliPathField, sampleRateField, threadsField, promptField,
         durationField, offsetField, obsidianVaultPathField, obsidianFolderField,
         diarizeThresholdField, diarizeSpeakersField].forEach {
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
        obsidianSaveCheckbox = NSButton(checkboxWithTitle: "🪨 Save copy directly to Obsidian vault", target: nil, action: nil)

        promptField.placeholderString = "Names, jargon, context…"
        durationField.placeholderString = "0 = full file"
        offsetField.placeholderString = "0 = from start"
        obsidianVaultPathField.placeholderString = "Select or paste vault path"
        obsidianFolderField.placeholderString = "Transcriptions (default)"
        diarizeThresholdField.placeholderString = "0.65"
        diarizeSpeakersField.placeholderString = "0 (Auto-detect)"
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

    @objc private func checkWhisperUpdate(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = "Checking..."
        
        let fm = FileManager.default
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = pathEnv.split(separator: ":").map { String($0) }
        var resolvedBrew: String? = nil
        for p in ["/opt/homebrew/bin", "/usr/local/bin"] + paths {
            let candidate = (p as NSString).appendingPathComponent("brew")
            if fm.fileExists(atPath: candidate) {
                resolvedBrew = candidate
                break
            }
        }
        let brewPath = resolvedBrew ?? "/opt/homebrew/bin/brew"
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brewPath)
        proc.arguments = ["info", "whisper-cpp"]
        
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        proc.environment = env
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
                proc.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "No output from brew info."
                
                DispatchQueue.main.async {
                    sender.isEnabled = true
                    sender.title = "Check for Updates"
                    
                    let alert = NSAlert()
                    alert.messageText = "Whisper Update Check"
                    alert.informativeText = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                DispatchQueue.main.async {
                    sender.isEnabled = true
                    sender.title = "Check for Updates"
                    
                    let alert = NSAlert()
                    alert.messageText = "Update Check Failed"
                    alert.informativeText = "Could not run brew: \(error.localizedDescription)\n\nMake sure Homebrew is installed and on your PATH."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    @objc private func checkSherpaUpdate(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = "Checking..."
        
        let fm = FileManager.default
        var pythonPath = "/usr/bin/python3"
        if fm.fileExists(atPath: "/opt/homebrew/bin/python3") {
            pythonPath = "/opt/homebrew/bin/python3"
        } else if fm.fileExists(atPath: "/usr/local/bin/python3") {
            pythonPath = "/usr/local/bin/python3"
        }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-c", """
import sys, urllib.request, json
try:
    import sherpa_onnx
    curr = sherpa_onnx.__version__
except ImportError:
    print("sherpa-onnx is not installed. Run 'pip3 install sherpa-onnx --break-system-packages' first.")
    sys.exit(0)

try:
    req = urllib.request.Request('https://pypi.org/pypi/sherpa-onnx/json', headers={'User-Agent': 'Mozilla/5.0'})
    latest = json.loads(urllib.request.urlopen(req, timeout=5).read().decode())['info']['version']
    if curr == latest:
        print(f"sherpa-onnx is up-to-date (version: {curr}).")
    else:
        print(f"Update available for sherpa-onnx!\\n\\nInstalled: {curr}\\nLatest: {latest}\\n\\nTo upgrade, run:\\npip3 install sherpa-onnx --upgrade --break-system-packages")
except Exception as e:
    print(f"Installed: {curr}\\nFailed to check PyPI for updates: {e}")
"""]
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
                proc.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "No output from update checker."
                
                DispatchQueue.main.async {
                    sender.isEnabled = true
                    sender.title = "Check for Updates"
                    
                    let alert = NSAlert()
                    alert.messageText = "Sherpa-ONNX Update Check"
                    alert.informativeText = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                DispatchQueue.main.async {
                    sender.isEnabled = true
                    sender.title = "Check for Updates"
                    
                    let alert = NSAlert()
                    alert.messageText = "Update Check Failed"
                    alert.informativeText = "Could not run python: \(error.localizedDescription)"
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    @objc private func checkDependenciesClicked(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = "Checking..."
        
        let fm = FileManager.default
        var report = "=== DEPENDENCY DIAGNOSTICS ===\n\n"
        
        report += "● Whisper GUI Version: 1.2.0\n"
        report += "   Status: Active & running\n\n"
        
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = pathEnv.split(separator: ":").map { String($0) }
        var resolvedBrew: String? = nil
        for p in ["/opt/homebrew/bin", "/usr/local/bin"] + paths {
            let candidate = (p as NSString).appendingPathComponent("brew")
            if fm.fileExists(atPath: candidate) {
                resolvedBrew = candidate
                break
            }
        }
        if let brew = resolvedBrew {
            report += "✔ Homebrew: Found at \(brew)\n"
        } else {
            report += "✘ Homebrew: Not found in PATH\n"
        }
        
        let resolvedFfmpeg = self.settings.ffmpegPath
        if fm.fileExists(atPath: resolvedFfmpeg) {
            report += "✔ ffmpeg: Found at \(resolvedFfmpeg)\n"
        } else {
            report += "✘ ffmpeg: Not found at \(resolvedFfmpeg)\n"
        }
        
        let resolvedCli = self.settings.cliPath
        if fm.fileExists(atPath: resolvedCli) {
            report += "✔ whisper-cli: Found at \(resolvedCli)\n"
        } else {
            report += "✘ whisper-cli: Not found at \(resolvedCli)\n"
        }
        
        var pythonPath = "/usr/bin/python3"
        if fm.fileExists(atPath: "/opt/homebrew/bin/python3") {
            pythonPath = "/opt/homebrew/bin/python3"
        } else if fm.fileExists(atPath: "/usr/local/bin/python3") {
            pythonPath = "/usr/local/bin/python3"
        }
        if fm.fileExists(atPath: pythonPath) {
            report += "✔ Python 3: Found at \(pythonPath)\n"
            
            let sherpaProc = Process()
            sherpaProc.executableURL = URL(fileURLWithPath: pythonPath)
            sherpaProc.arguments = ["-c", "import sherpa_onnx; print(sherpa_onnx.__version__)"]
            let sherpaPipe = Pipe()
            sherpaProc.standardOutput = sherpaPipe
            sherpaProc.standardError = Pipe()
            var sherpaStatus = "   - sherpa-onnx: Not found (Optional - run 'pip3 install sherpa-onnx --break-system-packages' for deep speaker identification)\n"
            do {
                try sherpaProc.run()
                sherpaProc.waitUntilExit()
                if sherpaProc.terminationStatus == 0 {
                    let data = sherpaPipe.fileHandleForReading.readDataToEndOfFile()
                    if let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
                        sherpaStatus = "   - sherpa-onnx: Found version \(version)\n"
                    }
                }
            } catch {}
            report += sherpaStatus
        } else {
            report += "✘ Python 3: Not found\n"
        }
        
        var enginePath = "/Users/dfe/whisper-gui/speaker_engine.py"
        if !fm.fileExists(atPath: enginePath) {
            if let resourcePath = Bundle.main.path(forResource: "speaker_engine", ofType: "py") {
                enginePath = resourcePath
            } else {
                enginePath = fm.currentDirectoryPath + "/speaker_engine.py"
            }
        }
        if fm.fileExists(atPath: enginePath) {
            report += "✔ Speaker Engine: Found at \(enginePath)\n"
        } else {
            report += "✘ Speaker Engine: Not found (diarization disabled)\n"
        }
        
        if let brew = resolvedBrew {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: brew)
            proc.arguments = ["info", "whisper-cpp"]
            
            var env = ProcessInfo.processInfo.environment
            let path = env["PATH"] ?? ""
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
            proc.environment = env
            
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                        let firstLines = output.split(separator: "\n").prefix(3).joined(separator: "\n")
                        report += "\n==> Brew whisper-cpp Info:\n\(firstLines)\n"
                    }
                } catch {}
                
                DispatchQueue.main.async {
                    sender.isEnabled = true
                    sender.title = "Check Dependencies"
                    
                    let alert = NSAlert()
                    alert.messageText = "Dependency Diagnostics"
                    alert.informativeText = report
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        } else {
            sender.isEnabled = true
            sender.title = "Check Dependencies"
            
            let alert = NSAlert()
            alert.messageText = "Dependency Diagnostics"
            alert.informativeText = report + "\nHomebrew is not installed or not in PATH."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func pickObsidianVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Obsidian Vault"
        if panel.runModal() == .OK, let url = panel.url {
            obsidianVaultPathField.stringValue = url.path
            statusLabel.stringValue = "Obsidian Vault linked: \(url.lastPathComponent)"
        }
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
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 80).isActive = true
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

        originalSourcePath = path
        setTranscribingState(active: true, title: "Preparing...")
        statusLabel.stringValue = "Preparing…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let ready = try self.resolveAudioPath(path)
                DispatchQueue.main.async {
                    self.audioField.stringValue = ready
                    self.setTranscribingState(active: false)
                    self.statusLabel.stringValue = "Ready — click Transcribe or drop another file."
                    self.setupPreviewPlayer(path: ready)
                    if autoTranscribe {
                        self.runTranscribe()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.setTranscribingState(active: false)
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

    @objc private func chooseTagsClicked(_ sender: NSButton) {
        let menu = NSMenu()
        let activeTags = tagsField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        
        for option in tagOptions {
            let item = NSMenuItem(title: option, action: #selector(tagMenuItemClicked(_:)), keyEquivalent: "")
            item.target = self
            if activeTags.contains(option.lowercased()) {
                item.state = .on
            } else {
                item.state = .off
            }
            menu.addItem(item)
        }
        
        let p = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: p, in: sender)
    }

    @objc private func tagMenuItemClicked(_ sender: NSMenuItem) {
        let option = sender.title
        var activeTags = tagsField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if let index = activeTags.firstIndex(where: { $0.lowercased() == option.lowercased() }) {
            activeTags.remove(at: index)
        } else {
            activeTags.append(option)
        }
        
        tagsField.stringValue = activeTags.joined(separator: ", ")
    }

    // MARK: - Audio Preview Player Helpers

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func setupPreviewPlayer(path: String) {
        // Reset previous player if any
        previewPlayer?.stop()
        previewPlayer = nil
        stopPreviewTimer()

        let fileURL = URL(fileURLWithPath: path)
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.prepareToPlay()
            previewPlayer = player

            previewPlayButton.title = "▶"
            previewPlayButton.isEnabled = true
            previewSlider.isEnabled = true
            previewSlider.doubleValue = 0
            previewSlider.maxValue = player.duration

            previewTimeLabel.stringValue = "00:00 / \(formatTime(player.duration))"
            previewPlayerRow?.isHidden = false
        } catch {
            previewPlayerRow?.isHidden = true
            appendLog("Could not initialize preview audio player: \(error.localizedDescription)\n")
        }
    }

    @objc private func playPausePreviewClicked() {
        guard let player = previewPlayer else { return }
        if player.isPlaying {
            player.pause()
            previewPlayButton.title = "▶"
            stopPreviewTimer()
        } else {
            // Pause browser player if playing to prevent overlapping audio
            if let bp = browserPlayer, bp.isPlaying {
                bp.pause()
                browserPlayButton.title = "▶"
                stopBrowserTimer()
            }
            player.play()
            previewPlayButton.title = "❚❚"
            startPreviewTimer()
        }
    }

    @objc private func previewSliderDragged() {
        guard let player = previewPlayer else { return }
        player.currentTime = previewSlider.doubleValue
        updatePreviewTimeLabel()
    }

    private func startPreviewTimer() {
        stopPreviewTimer()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.previewPlayer else { return }
            self.previewSlider.doubleValue = player.currentTime
            self.updatePreviewTimeLabel()
        }
    }

    private func stopPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    private func updatePreviewTimeLabel() {
        guard let player = previewPlayer else { return }
        previewTimeLabel.stringValue = "\(formatTime(player.currentTime)) / \(formatTime(player.duration))"
    }

    // MARK: - Browser Audio Sync Helpers

    private func disableBrowserPlayer() {
        browserPlayer?.stop()
        browserPlayer = nil
        stopBrowserTimer()
        browserPlayButton.isEnabled = false
        browserSlider.isEnabled = false
        browserTimeLabel.stringValue = "No active audio loaded"
    }

    private func setupBrowserPlayer(content: String) {
        disableBrowserPlayer()
        timestampRanges.removeAll()

        var audioPath: String?
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Path: ") {
                audioPath = trimmed.replacingOccurrences(of: "Path: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                break
            } else if trimmed.hasPrefix("source_file: ") {
                audioPath = trimmed.replacingOccurrences(of: "source_file: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                audioPath = audioPath?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                break
            }
        }

        guard let path = audioPath, FileManager.default.fileExists(atPath: path) else {
            return
        }

        let fileURL = URL(fileURLWithPath: path)
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.prepareToPlay()
            browserPlayer = player
            browserAudioURL = fileURL

            browserPlayButton.title = "▶"
            browserPlayButton.isEnabled = true
            browserSlider.isEnabled = true
            browserSlider.doubleValue = 0
            browserSlider.maxValue = player.duration

            browserTimeLabel.stringValue = "\(fileURL.lastPathComponent) [00:00 / \(formatTime(player.duration))]"
            browserPlayerRow?.isHidden = false

            parseTimestampsInBrowserText(content)
        } catch {
            appendLog("Could not initialize browser audio player: \(error.localizedDescription)\n")
        }
    }

    private func parseTimestampsInBrowserText(_ content: String) {
        timestampRanges.removeAll()
        let lines = content.components(separatedBy: .newlines)
        
        let patLog = "\\[(\\d{2}):(\\d{2})(?:\\.(\\d{2,3}))?(?:\\s*->\\s*(\\d{2}):(\\d{2})(?:\\.(\\d{2,3}))?)?\\]"
        let patSrt = "(\\d{2}):(\\d{2}):(\\d{2})[,,\\. ](\\d{3})\\s*-->\\s*(\\d{2}):(\\d{2}):(\\d{2})[,,\\. ](\\d{3})"
        let patVttShort = "(\\d{2}):(\\d{2})[,,\\. ](\\d{3})\\s*-->\\s*(\\d{2}):(\\d{2})[,,\\. ](\\d{3})"
        
        guard let regLog = try? NSRegularExpression(pattern: patLog, options: []),
              let regSrt = try? NSRegularExpression(pattern: patSrt, options: []),
              let regVttShort = try? NSRegularExpression(pattern: patVttShort, options: []) else {
            return
        }
        
        var currentOffset = 0
        for line in lines {
            let lineRange = NSRange(location: currentOffset, length: (line as NSString).length)
            let lineStr = line
            
            // Try Log
            if let m = regLog.firstMatch(in: lineStr, options: [], range: NSRange(location: 0, length: (lineStr as NSString).length)) {
                if m.numberOfRanges > 2 {
                    let startMin = (lineStr as NSString).substring(with: m.range(at: 1))
                    let startSec = (lineStr as NSString).substring(with: m.range(at: 2))
                    var startMs: String?
                    if m.range(at: 3).location != NSNotFound {
                        startMs = (lineStr as NSString).substring(with: m.range(at: 3))
                    }
                    let start = parseTimeValue(mins: startMin, secs: startSec, ms: startMs)
                    
                    var end = start + 3.0
                    if m.numberOfRanges > 5, m.range(at: 4).location != NSNotFound, m.range(at: 5).location != NSNotFound {
                        let endMin = (lineStr as NSString).substring(with: m.range(at: 4))
                        let endSec = (lineStr as NSString).substring(with: m.range(at: 5))
                        var endMs: String?
                        if m.range(at: 6).location != NSNotFound {
                            endMs = (lineStr as NSString).substring(with: m.range(at: 6))
                        }
                        end = parseTimeValue(mins: endMin, secs: endSec, ms: endMs)
                    }
                    timestampRanges.append((start: start, end: end, range: lineRange))
                }
            }
            // Try SRT
            else if let m = regSrt.firstMatch(in: lineStr, options: [], range: NSRange(location: 0, length: (lineStr as NSString).length)) {
                if m.numberOfRanges > 8 {
                    let sHr = Double((lineStr as NSString).substring(with: m.range(at: 1))) ?? 0
                    let sMin = Double((lineStr as NSString).substring(with: m.range(at: 2))) ?? 0
                    let sSec = Double((lineStr as NSString).substring(with: m.range(at: 3))) ?? 0
                    let sMs = Double((lineStr as NSString).substring(with: m.range(at: 4))) ?? 0
                    let start = sHr * 3600.0 + sMin * 60.0 + sSec + sMs * 0.001
                    
                    let eHr = Double((lineStr as NSString).substring(with: m.range(at: 5))) ?? 0
                    let eMin = Double((lineStr as NSString).substring(with: m.range(at: 6))) ?? 0
                    let eSec = Double((lineStr as NSString).substring(with: m.range(at: 7))) ?? 0
                    let eMs = Double((lineStr as NSString).substring(with: m.range(at: 8))) ?? 0
                    let end = eHr * 3600.0 + eMin * 60.0 + eSec + eMs * 0.001
                    
                    timestampRanges.append((start: start, end: end, range: lineRange))
                }
            }
            // Try VTT Short
            else if let m = regVttShort.firstMatch(in: lineStr, options: [], range: NSRange(location: 0, length: (lineStr as NSString).length)) {
                if m.numberOfRanges > 6 {
                    let sMin = Double((lineStr as NSString).substring(with: m.range(at: 1))) ?? 0
                    let sSec = Double((lineStr as NSString).substring(with: m.range(at: 2))) ?? 0
                    let sMs = Double((lineStr as NSString).substring(with: m.range(at: 3))) ?? 0
                    let start = sMin * 60.0 + sSec + sMs * 0.001
                    
                    let eMin = Double((lineStr as NSString).substring(with: m.range(at: 4))) ?? 0
                    let eSec = Double((lineStr as NSString).substring(with: m.range(at: 5))) ?? 0
                    let eMs = Double((lineStr as NSString).substring(with: m.range(at: 6))) ?? 0
                    let end = eMin * 60.0 + eSec + eMs * 0.001
                    
                    timestampRanges.append((start: start, end: end, range: lineRange))
                }
            }
            
            currentOffset += lineRange.length + 1
        }
    }

    private func parseTimeValue(mins: String, secs: String, ms: String?) -> Double {
        let m = Double(mins) ?? 0
        let s = Double(secs) ?? 0
        let milli = Double(ms ?? "0") ?? 0
        let milliFactor = (ms?.count == 2) ? 0.01 : 0.001
        return m * 60.0 + s + milli * milliFactor
    }

    @objc private func playPauseBrowserClicked() {
        guard let player = browserPlayer else { return }
        if player.isPlaying {
            player.pause()
            browserPlayButton.title = "▶"
            stopBrowserTimer()
        } else {
            if let pp = previewPlayer, pp.isPlaying {
                pp.pause()
                previewPlayButton.title = "▶"
                stopPreviewTimer()
            }
            player.play()
            browserPlayButton.title = "❚❚"
            startBrowserTimer()
        }
    }

    @objc private func browserSliderDragged() {
        guard let player = browserPlayer else { return }
        player.currentTime = browserSlider.doubleValue
        updateBrowserTimeLabel()
        highlightActiveTimestampLine()
    }

    private func startBrowserTimer() {
        stopBrowserTimer()
        browserTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.browserPlayer else { return }
            self.browserSlider.doubleValue = player.currentTime
            self.updateBrowserTimeLabel()
            self.highlightActiveTimestampLine()
        }
    }

    private func stopBrowserTimer() {
        browserTimer?.invalidate()
        browserTimer = nil
    }

    private func updateBrowserTimeLabel() {
        guard let player = browserPlayer, let url = browserAudioURL else { return }
        browserTimeLabel.stringValue = "\(url.lastPathComponent) [\(formatTime(player.currentTime)) / \(formatTime(player.duration))]"
    }

    private func highlightActiveTimestampLine() {
        guard let player = browserPlayer else { return }
        let time = player.currentTime

        guard let matched = timestampRanges.first(where: { time >= $0.start && time <= $0.end }) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let storage = self.browserTextView.textStorage
            let len = storage?.length ?? 0
            guard len > 0 else { return }

            self.browserTextView.delegate = nil
            storage?.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: len))
            
            let text = self.browserTextView.string
            let lines = text.components(separatedBy: .newlines)
            var currentOffset = 0
            for line in lines {
                let lineLength = (line as NSString).length
                let lineRange = NSRange(location: currentOffset, length: lineLength)
                
                if let speaker = self.extractSpeaker(from: line) {
                    let colors = self.getSpeakerColors(for: speaker)
                    if lineRange.location == matched.range.location && lineRange.length == matched.range.length {
                        storage?.addAttribute(.backgroundColor, value: colors.active, range: lineRange)
                    } else {
                        storage?.addAttribute(.backgroundColor, value: colors.bg, range: lineRange)
                    }
                } else if lineRange.location == matched.range.location && lineRange.length == matched.range.length {
                    storage?.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), range: lineRange)
                }
                currentOffset += lineLength + 1
            }
            
            self.browserTextView.scrollRangeToVisible(matched.range)
            self.browserTextView.delegate = self
        }
    }

    // MARK: - Obsidian Integration Helpers

    private func scanObsidianTags(vaultPath: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: vaultPath), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var uniqueTags = Set<String>()
        let inlineRegex = try? NSRegularExpression(pattern: "#([a-zA-Z][a-zA-Z0-9_\\-\\/]*)", options: [])

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "md" else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let lines = content.components(separatedBy: .newlines)
            var inFrontmatter = false
            var frontmatterLines = [String]()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "---" {
                    if inFrontmatter {
                        break
                    } else {
                        inFrontmatter = true
                        continue
                    }
                }
                if inFrontmatter {
                    frontmatterLines.append(line)
                }
            }

            var frontmatterTags = [String]()
            var yamlInTagBlock = false
            for fmLine in frontmatterLines {
                let trimmed = fmLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased().hasPrefix("tags:") || trimmed.lowercased().hasPrefix("tag:") {
                    let parts = fmLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                    if parts.count > 1 {
                        let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if val.hasPrefix("[") && val.hasSuffix("]") {
                            let arrayVal = val.dropFirst().dropLast()
                            let arrayParts = arrayVal.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            frontmatterTags.append(contentsOf: arrayParts.map { String($0) })
                        } else if !val.isEmpty {
                            frontmatterTags.append(val)
                        } else {
                            yamlInTagBlock = true
                        }
                    }
                } else if yamlInTagBlock {
                    if trimmed.hasPrefix("-") {
                        let val = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                        frontmatterTags.append(val)
                    } else if fmLine.contains(":") {
                        yamlInTagBlock = false
                    }
                }
            }

            for t in frontmatterTags {
                let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
                if !cleaned.isEmpty {
                    uniqueTags.insert(cleaned.lowercased())
                }
            }

            if let regex = inlineRegex {
                let nsText = content as NSString
                let matches = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsText.length))
                for m in matches {
                    if m.numberOfRanges > 1 {
                        let tRange = m.range(at: 1)
                        let t = nsText.substring(with: tRange)
                        uniqueTags.insert(t.lowercased())
                    }
                }
            }
        }
        return Array(uniqueTags).sorted()
    }

    @objc private func importObsidianTagsClicked() {
        collectSettingsFromUI()
        let path = settings.obsidianVaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            alert("Please configure your Obsidian Vault path under the Advanced settings tab first.")
            return
        }

        statusLabel.stringValue = "Scanning Obsidian Vault for tags…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let tags = self.scanObsidianTags(vaultPath: path)
            DispatchQueue.main.async {
                if tags.isEmpty {
                    self.statusLabel.stringValue = "No tags found in the linked vault."
                    self.alert("No tags discovered inside Obsidian vault:\n\(path)\n\nAdd tags with #tag or in frontmatter tags: [tag] inside your .md notes.")
                } else {
                    var merged = self.tagOptions
                    for t in tags {
                        if !merged.contains(t) {
                            merged.append(t)
                        }
                    }
                    let originalOptions = ["meeting", "conference", "bank", "lecture", "interview", "podcast"]
                    let newOnes = merged.filter { !originalOptions.contains($0) }.sorted()
                    let finalMerged = originalOptions + newOnes

                    self.tagOptions = finalMerged
                    self.statusLabel.stringValue = "Imported \(tags.count) tags from Obsidian!"
                    self.alert("Successfully imported \(tags.count) unique tags from your Obsidian Vault! Click 'Choose...' to select them.")
                }
            }
        }
    }

    private func autoDiscoverObsidianVault() {
        guard settings.obsidianVaultPath.isEmpty else { return }
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let configPath = homeDir.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")

        guard fm.fileExists(atPath: configPath.path) else { return }
        guard let data = try? Data(contentsOf: configPath) else { return }

        struct VaultConfig: Decodable {
            let path: String
            let ts: Int64?
            let open: Bool?
        }
        struct ObsidianConfig: Decodable {
            let vaults: [String: VaultConfig]
        }

        guard let config = try? JSONDecoder().decode(ObsidianConfig.self, from: data) else { return }

        let sortedVaults = config.vaults.values.sorted { (v1, v2) -> Bool in
            let ts1 = v1.ts ?? 0
            let ts2 = v2.ts ?? 0
            return ts1 > ts2
        }

        if let activeVault = sortedVaults.first {
            settings.obsidianVaultPath = activeVault.path
            SettingsStore.save(settings)
            obsidianVaultPathField.stringValue = activeVault.path
            statusLabel.stringValue = "Auto-detected Obsidian Vault: \(URL(fileURLWithPath: activeVault.path).lastPathComponent)"
        }
    }

    private func saveToObsidian(text: String, noteName: String, tags: String, sourceFile: String) {
        let vaultPath = settings.obsidianVaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vaultPath.isEmpty, settings.obsidianSaveDirectly else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: vaultPath) else { return }

        let subfolder = settings.obsidianFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDirURL = URL(fileURLWithPath: vaultPath).appendingPathComponent(subfolder.isEmpty ? "Transcriptions" : subfolder)

        do {
            try fm.createDirectory(at: targetDirURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            appendLog("\nFailed to create Obsidian folder: \(error.localizedDescription)\n")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let dateTimeStr = formatter.string(from: Date())
        
        var cleanNoteName = "Transcription \(dateTimeStr)"
        let customNoteName = noteName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customNoteName.isEmpty {
            cleanNoteName += " - \(customNoteName)"
        }

        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|#^[]")
        cleanNoteName = cleanNoteName.components(separatedBy: invalidCharacters).joined(separator: "_")
        if cleanNoteName.isEmpty {
            cleanNoteName = "Transcription"
        }

        let fileURL = targetDirURL.appendingPathComponent(cleanNoteName).appendingPathExtension("md")

        var content = "---\n"
        let tagList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !tagList.isEmpty {
            content += "tags:\n"
            for t in tagList {
                content += "  - \(t.lowercased())\n"
            }
        }

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let dateStr = isoFormatter.string(from: Date())
        content += "created: \(dateStr)\n"
        content += "source_file: \(sourceFile.isEmpty ? "None" : sourceFile)\n"
        content += "---\n\n"

        content += "# Transcription - \(dateTimeStr)\n"
        if !customNoteName.isEmpty {
            content += "## Note: \(customNoteName)\n"
        }
        content += "**Source Audio File:** `\(URL(fileURLWithPath: sourceFile).lastPathComponent)`\n"
        content += "**Path:** `\(sourceFile)`\n\n"
        content += "----------------------------------------\n\n"
        content += text

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            appendLog("\n[Obsidian] Note saved successfully:\n\(subfolder)/\(cleanNoteName).md\n")
        } catch {
            appendLog("\n[Obsidian] Failed to save note: \(error.localizedDescription)\n")
        }
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
        guard !isTranscribing else { return }
        collectSettingsFromUI()
        let audio = audioField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cli = settings.cliPath

        guard !audio.isEmpty else {
            alert("Drop a file or click Choose… first.")
            return
        }
        if originalSourcePath == nil {
            originalSourcePath = audio
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
        setTranscribingState(active: true, title: "Preparing...")
        statusLabel.stringValue = "Preparing…"
        progressStack?.isHidden = false
        progressBar?.doubleValue = 0.0
        progressLabel.stringValue = "0%"

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
                    self.setTranscribingState(active: false)
                    self.statusLabel.stringValue = "Preparation failed."
                    self.alert(error.localizedDescription)
                }
            }
        }
    }

    private func startWhisper(audio: String, model: String) {
        transcriptView.string = ""
        setTranscribingState(active: true, title: "Transcribing...")
        statusLabel.stringValue = "Transcribing…"

        let customName = customNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem: String
        if !customName.isEmpty {
            let dir = (audio as NSString).deletingLastPathComponent
            stem = (dir as NSString).appendingPathComponent(customName)
        } else {
            stem = (audio as NSString).deletingPathExtension
        }
        let cli = settings.cliPath
        var args = [cli, "-m", model, "-f", audio, "-t", String(settings.threads), "-l", settings.language]
        if !settings.useGpu { args.insert("-ng", at: 1) }
        if settings.translate { args.append("-tr") }
        if settings.printProgress { args.append("-pp") }
        if settings.noTimestamps && !settings.diarizeEnabled { args.append("-nt") }
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
            setTranscribingState(active: false)
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
        progressStack?.isHidden = true
    }

    // MARK: - Speaker Recognition Helpers
    
    private func getSpeakersDirectory() -> URL {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let baseDir = homeDir.appendingPathComponent(".config/whisper-gui/speakers", isDirectory: true)
        
        var pythonPath = "/usr/bin/python3"
        if fm.fileExists(atPath: "/opt/homebrew/bin/python3") {
            pythonPath = "/opt/homebrew/bin/python3"
        } else if fm.fileExists(atPath: "/usr/local/bin/python3") {
            pythonPath = "/usr/local/bin/python3"
        }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-c", "import sherpa_onnx"]
        
        let devNull = FileHandle.nullDevice
        proc.standardOutput = devNull
        proc.standardError = devNull
        
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let modelPath = homeDir.appendingPathComponent(".config/whisper-gui/models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")
                if fm.fileExists(atPath: modelPath.path) {
                    let sherpaDir = baseDir.appendingPathComponent("sherpa", isDirectory: true)
                    if !fm.fileExists(atPath: sherpaDir.path) {
                        try? fm.createDirectory(at: sherpaDir, withIntermediateDirectories: true)
                    }
                    return sherpaDir
                }
            }
        } catch {}
        
        return baseDir
    }

    private func refreshSpeakersList() {
        let fm = FileManager.default
        let speakersDir = getSpeakersDirectory()
        
        do {
            if !fm.fileExists(atPath: speakersDir.path) {
                try fm.createDirectory(at: speakersDir, withIntermediateDirectories: true)
            }
            let files = try fm.contentsOfDirectory(at: speakersDir, includingPropertiesForKeys: nil, options: [])
            let sigs = files.filter { url in
                let stem = url.deletingPathExtension().lastPathComponent
                let isTemp = stem.hasPrefix("Speaker ") && stem.dropFirst(8).allSatisfy({ $0.isNumber })
                return url.pathExtension.lowercased() == "sig" && !isTemp
            }.map { $0.deletingPathExtension().lastPathComponent }
            
            if !sigs.isEmpty {
                registeredSpeakersLabel.stringValue = "Registered: " + sigs.sorted().joined(separator: ", ")
            } else {
                registeredSpeakersLabel.stringValue = "None registered"
            }
        } catch {
            registeredSpeakersLabel.stringValue = "None registered"
        }
    }
    
    @objc private func diarizeToggled() {
        settings.diarizeEnabled = (diarizeCheckbox.state == .on)
        SettingsStore.save(settings)
    }
    
    // MARK: - Voice Training & Contacts Integration
    
    private func fetchContactsList() -> [(name: String, id: String)] {
        let store = CNContactStore()
        var results = [(name: String, id: String)]()
        
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return results }
        
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespacesAndNewlines)
                if !fullName.isEmpty {
                    results.append((name: fullName, id: contact.identifier))
                }
            }
        } catch {
            print("Failed to fetch contacts: \(error)")
        }
        
        return results
    }
    
    @objc private func registerVoiceClicked() {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        
        if status == .notDetermined {
            store.requestAccess(for: .contacts) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.showRegisterVoiceDialog()
                }
            }
        } else {
            showRegisterVoiceDialog()
        }
    }
    
    private func showRegisterVoiceDialog() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Register Voice Profile"
        window.center()
        
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.spacing = 12
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        
        // 1. Contact / Name Row
        let contactLabel = NSTextField(labelWithString: "Contact or Name:")
        contactLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        contactLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        
        registerVoiceCombo = NSComboBox()
        registerVoiceCombo.translatesAutoresizingMaskIntoConstraints = false
        registerVoiceCombo.completes = true
        registerVoiceCombo.placeholderString = "Search contacts or type name..."
        
        // Fetch contacts
        let contacts = fetchContactsList()
        for c in contacts {
            registerVoiceCombo.addItem(withObjectValue: c.name)
        }
        
        let contactRow = NSStackView(views: [contactLabel, registerVoiceCombo])
        contactRow.orientation = .horizontal
        contactRow.spacing = 8
        contactRow.distribution = .fill
        
        // 2. Audio File Row
        let fileLabel = NSTextField(labelWithString: "Audio Sample:")
        fileLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        fileLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        
        registerVoiceFilePath = NSTextField()
        registerVoiceFilePath.translatesAutoresizingMaskIntoConstraints = false
        registerVoiceFilePath.placeholderString = "/path/to/voice_sample.wav"
        
        let browseBtn = NSButton(title: "Browse…", target: self, action: #selector(registerVoiceBrowseClicked))
        browseBtn.bezelStyle = .rounded
        browseBtn.translatesAutoresizingMaskIntoConstraints = false
        
        let fileRow = NSStackView(views: [fileLabel, registerVoiceFilePath, browseBtn])
        fileRow.orientation = .horizontal
        fileRow.spacing = 8
        fileRow.distribution = .fill
        
        // 3. Status row
        registerVoiceStatus = NSTextField(labelWithString: "")
        registerVoiceStatus.textColor = .secondaryLabelColor
        registerVoiceStatus.font = NSFont.systemFont(ofSize: 11)
        registerVoiceStatus.translatesAutoresizingMaskIntoConstraints = false
        
        // 4. Actions Row
        registerVoiceSubmitBtn = NSButton(title: "Extract & Register", target: self, action: #selector(registerVoiceSubmitClicked))
        registerVoiceSubmitBtn.bezelStyle = .rounded
        registerVoiceSubmitBtn.translatesAutoresizingMaskIntoConstraints = false
        
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(registerVoiceCancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        
        let actionsRow = NSStackView(views: [cancelBtn, registerVoiceSubmitBtn])
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 12
        actionsRow.alignment = .right
        actionsRow.distribution = .fill
        
        mainStack.addArrangedSubview(contactRow)
        mainStack.addArrangedSubview(fileRow)
        mainStack.addArrangedSubview(registerVoiceStatus)
        mainStack.addArrangedSubview(actionsRow)
        
        window.contentView = mainStack
        self.registerVoiceWindow = window
        
        NSApp.runModal(for: window)
    }
    
    @objc private func registerVoiceBrowseClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .audio, .mp3]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            registerVoiceFilePath.stringValue = url.path
        }
    }
    
    @objc private func registerVoiceCancelClicked() {
        if let win = registerVoiceWindow {
            NSApp.stopModal(withCode: .cancel)
            win.close()
        }
    }
    
    @objc private func registerVoiceSubmitClicked() {
        let nameInput = registerVoiceCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioPath = registerVoiceFilePath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !nameInput.isEmpty else {
            registerVoiceStatus.stringValue = "⚠️ Please select a contact or enter a name."
            registerVoiceStatus.textColor = .systemRed
            return
        }
        guard !audioPath.isEmpty, FileManager.default.fileExists(atPath: audioPath) else {
            registerVoiceStatus.stringValue = "⚠️ Please select a valid audio file."
            registerVoiceStatus.textColor = .systemRed
            return
        }
        
        registerVoiceSubmitBtn.isEnabled = false
        registerVoiceStatus.stringValue = "Extracting voice footprint and registering..."
        registerVoiceStatus.textColor = .labelColor
        
        runSpeakerLearnProcess(name: nameInput, audioPath: audioPath) { [weak self] success, msg in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if success {
                    self.registerVoiceStatus.stringValue = "✔ Successfully registered speaker profile!"
                    self.registerVoiceStatus.textColor = .systemGreen
                    self.refreshSpeakersList()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if let win = self.registerVoiceWindow {
                            NSApp.stopModal(withCode: .OK)
                            win.close()
                        }
                    }
                } else {
                    self.registerVoiceStatus.stringValue = "✘ Error: \(msg)"
                    self.registerVoiceStatus.textColor = .systemRed
                    self.registerVoiceSubmitBtn.isEnabled = true
                }
            }
        }
    }
    
    private func runSpeakerLearnProcess(name: String, audioPath: String, completion: @escaping (Bool, String) -> Void) {
        let fm = FileManager.default
        var pythonPath = "/usr/bin/python3"
        if fm.fileExists(atPath: "/opt/homebrew/bin/python3") {
            pythonPath = "/opt/homebrew/bin/python3"
        } else if fm.fileExists(atPath: "/usr/local/bin/python3") {
            pythonPath = "/usr/local/bin/python3"
        }
        
        let resourcesPath = Bundle.main.resourcePath ?? ""
        var enginePath = (resourcesPath as NSString).appendingPathComponent("speaker_engine.py")
        if !fm.fileExists(atPath: enginePath) {
            enginePath = "/Users/dfe/whisper-gui/speaker_engine.py"
        }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [enginePath, "--learn", name, audioPath]
        
        var env = ProcessInfo.processInfo.environment
        let pathEnv = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + pathEnv
        proc.environment = env
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        proc.terminationHandler = { p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if p.terminationStatus == 0 {
                completion(true, output)
            } else {
                completion(false, output.isEmpty ? "Extraction failed" : output)
            }
        }
        
        do {
            try proc.run()
        } catch {
            completion(false, error.localizedDescription)
        }
    }
    

    private func extractSpeaker(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        let lowerTrimmed = trimmed.lowercased()
        for prefix in ["file:", "path:", "tags:", "created:", "note:", "title:", "source_file:", "---"] {
            if lowerTrimmed.hasPrefix(prefix) {
                return nil
            }
        }
        
        guard let colonRange = trimmed.range(of: ":") else { return nil }
        let speakerPart = String(trimmed[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if speakerPart.count > 0 && speakerPart.count < 30 {
            let invalidChars = CharacterSet(charactersIn: "[]<>-")
            if speakerPart.rangeOfCharacter(from: invalidChars) == nil {
                if Int(speakerPart) == nil {
                    return speakerPart
                }
            }
        }
        return nil
    }
    
    private func getSpeakerColors(for speaker: String?) -> (bg: NSColor, active: NSColor) {
        guard let speaker = speaker, speaker != "Unknown Speaker" else {
            return (NSColor(white: 0.15, alpha: 0.5), NSColor(white: 0.25, alpha: 0.7))
        }
        
        let colors: [(bg: NSColor, active: NSColor)] = [
            (NSColor(red: 0.12, green: 0.22, blue: 0.35, alpha: 0.6), NSColor(red: 0.18, green: 0.30, blue: 0.48, alpha: 0.8)), // Blue
            (NSColor(red: 0.10, green: 0.25, blue: 0.18, alpha: 0.6), NSColor(red: 0.15, green: 0.35, blue: 0.25, alpha: 0.8)), // Green
            (NSColor(red: 0.20, green: 0.15, blue: 0.30, alpha: 0.6), NSColor(red: 0.30, green: 0.22, blue: 0.45, alpha: 0.8)), // Purple
            (NSColor(red: 0.28, green: 0.18, blue: 0.10, alpha: 0.6), NSColor(red: 0.40, green: 0.25, blue: 0.15, alpha: 0.8)), // Orange
            (NSColor(red: 0.28, green: 0.15, blue: 0.20, alpha: 0.6), NSColor(red: 0.40, green: 0.22, blue: 0.30, alpha: 0.8)), // Pink
            (NSColor(red: 0.10, green: 0.25, blue: 0.28, alpha: 0.6), NSColor(red: 0.15, green: 0.35, blue: 0.40, alpha: 0.8))  // Cyan
        ]
        
        let hash = speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[hash % colors.count]
    }
    
    private func applySpeakerColoringToBrowserText() {
        guard let storage = browserTextView.textStorage else { return }
        let text = browserTextView.string
        let lines = text.components(separatedBy: .newlines)
        
        browserTextView.delegate = nil
        var currentOffset = 0
        for line in lines {
            let lineLength = (line as NSString).length
            let lineRange = NSRange(location: currentOffset, length: lineLength)
            
            if let speaker = extractSpeaker(from: line) {
                let colors = getSpeakerColors(for: speaker)
                storage.addAttribute(.backgroundColor, value: colors.bg, range: lineRange)
            }
            currentOffset += lineLength + 1
        }
        browserTextView.delegate = self
    }

    private func makeTranscriptHeader() -> String {
        let path = originalSourcePath ?? (audioField.stringValue.isEmpty ? nil : audioField.stringValue)
        guard let p = path, FileManager.default.fileExists(atPath: p) else {
            return ""
        }
        let fileURL = URL(fileURLWithPath: p)
        let filename = fileURL.lastPathComponent
        
        let fm = FileManager.default
        var dateStr = "Unknown"
        if let attrs = try? fm.attributesOfItem(atPath: p) {
            let date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
            if let d = date {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .medium
                dateStr = formatter.string(from: d)
            }
        }
        
        var header = "File: \(filename)\n"
        header += "Path: \(p)\n"
        let noteName = noteNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !noteName.isEmpty {
            header += "Note: \(noteName)\n"
        }
        let customTitle = customNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customTitle.isEmpty {
            header += "Title: \(customTitle)\n"
        }
        let selectedTags = tagsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedTags.isEmpty {
            header += "Tags: \(selectedTags)\n"
        }
        header += "Created: \(dateStr)\n"
        header += "----------------------------------------\n\n\n"
        return header
    }

    private func extractTimestampedTranscriptFromLog() -> String {
        let log = logView.string
        var lines: [String] = []
        let pat = "\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\s*-+>\\s*\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\]"
        let patShort = "\\[\\d{2}:\\d{2}\\.\\d{3}\\s*-+>\\s*\\d{2}:\\d{2}\\.\\d{3}\\]"
        guard let reg = try? NSRegularExpression(pattern: pat, options: []),
              let regShort = try? NSRegularExpression(pattern: patShort, options: []) else {
            return ""
        }
        
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if reg.firstMatch(in: trimmed, options: [], range: range) != nil ||
               regShort.firstMatch(in: trimmed, options: [], range: range) != nil {
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func runDiarizationAndProceed(audioStem: String, audioPath: String, exitCode: Int32) {
        let fm = FileManager.default
        let txtPath = audioStem + ".txt"
        
        var enginePath = "/Users/dfe/whisper-gui/speaker_engine.py"
        if !fm.fileExists(atPath: enginePath) {
            if let resourcePath = Bundle.main.path(forResource: "speaker_engine", ofType: "py") {
                enginePath = resourcePath
            } else {
                enginePath = fm.currentDirectoryPath + "/speaker_engine.py"
            }
        }
        
        guard fm.fileExists(atPath: enginePath) else {
            self.onFinishedProceed(exitCode: exitCode, audioStem: audioStem)
            return
        }
        
        let timestampedText = extractTimestampedTranscriptFromLog()
        guard !timestampedText.isEmpty else {
            appendLog("Diarization skipped: No timestamped segments found in the transcription log.\n")
            self.onFinishedProceed(exitCode: exitCode, audioStem: audioStem)
            return
        }
        
        do {
            try timestampedText.write(toFile: txtPath, atomically: true, encoding: .utf8)
        } catch {
            appendLog("Failed to write timestamped transcript: \(error.localizedDescription)\n")
            self.onFinishedProceed(exitCode: exitCode, audioStem: audioStem)
            return
        }
        
        appendLog("\n--- speaker diarization ---\n")
        appendLog("Transcript path: \(txtPath)\n")
        appendLog("Audio path: \(audioPath)\n")
        appendLog("Extracted \(timestampedText.split(separator: "\n").count) timestamped lines for diarization.\n")
        
        statusLabel.stringValue = "Running speaker diarization..."
        
        var pythonPath = "/usr/bin/python3"
        if fm.fileExists(atPath: "/opt/homebrew/bin/python3") {
            pythonPath = "/opt/homebrew/bin/python3"
        } else if fm.fileExists(atPath: "/usr/local/bin/python3") {
            pythonPath = "/usr/local/bin/python3"
        }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        
        var diarizeArgs = [enginePath, "--diarize", txtPath, audioPath]
        diarizeArgs.append("--threshold")
        diarizeArgs.append(String(settings.diarizeThreshold))
        diarizeArgs.append("--max-speakers")
        diarizeArgs.append(String(settings.diarizeSpeakers))
        
        proc.arguments = diarizeArgs
        
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        proc.environment = env
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        appendLog("Running: \(pythonPath) \(diarizeArgs.joined(separator: " "))\n\n")
        
        let fd = pipe.fileHandleForReading.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        
        source.setEventHandler { [weak self] in
            let data = pipe.fileHandleForReading.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.appendLog(text) }
        }
        
        source.setCancelHandler {
            pipe.fileHandleForReading.closeFile()
        }
        
        proc.terminationHandler = { [weak self] p in
            source.cancel()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if p.terminationStatus != 0 {
                    self.appendLog("\nDiarization process exited with non-zero code \(p.terminationStatus)\n")
                } else {
                    self.appendLog("\nDiarization process completed successfully.\n")
                }
                self.onFinishedProceed(exitCode: exitCode, audioStem: audioStem)
            }
        }
        
        do {
            try proc.run()
            source.resume()
        } catch {
            source.cancel()
            appendLog("Diarization launch failed: \(error.localizedDescription)\n")
            self.onFinishedProceed(exitCode: exitCode, audioStem: audioStem)
        }
    }

    private func onFinished(exitCode: Int32, audioStem: String) {
        if exitCode == 0 && settings.diarizeEnabled {
            let audio = audioField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            runDiarizationAndProceed(audioStem: audioStem, audioPath: audio, exitCode: exitCode)
        } else {
            onFinishedProceed(exitCode: exitCode, audioStem: audioStem)
        }
    }

    private func onFinishedProceed(exitCode: Int32, audioStem: String) {
        readSource?.cancel()
        readSource = nil
        process = nil
        setTranscribingState(active: false)
        progressStack?.isHidden = true

        let header = makeTranscriptHeader()

        let candidates = [
            settings.outputTxt ? audioStem + ".txt" : nil,
            settings.outputSrt ? audioStem + ".srt" : nil,
            settings.outputVtt ? audioStem + ".vtt" : nil,
            settings.outputJson ? audioStem + ".json" : nil,
        ].compactMap { $0 }
        if let found = candidates.first(where: { loadTranscriptText(txtPath: $0) != nil }),
           let text = loadTranscriptText(txtPath: found) {
            let noteText: String
            if found.hasSuffix(".txt") {
                if !text.hasPrefix("File: ") || !text.contains("----------------------------------------") {
                    let updatedText = header + text
                    try? updatedText.write(toFile: found, atomically: true, encoding: .utf8)
                    transcriptView.string = updatedText
                    noteText = text
                } else {
                    transcriptView.string = text
                    // Strip the header to get the pure transcription text for Obsidian
                    if let separatorRange = text.range(of: "----------------------------------------\n\n\n") {
                        noteText = String(text[separatorRange.upperBound...])
                    } else {
                        noteText = text
                    }
                }
            } else {
                transcriptView.string = header + text
                noteText = text
            }
            statusLabel.stringValue = "Done — saved \(found)"
            saveToObsidian(text: noteText, noteName: noteNameField.stringValue, tags: tagsField.stringValue, sourceFile: audioField.stringValue)
        } else if exitCode == 0, let fallback = extractTranscriptFromLog() {
            transcriptView.string = header + fallback
            statusLabel.stringValue = "Done (from log; .txt not found at expected path)."
            saveToObsidian(text: fallback, noteName: noteNameField.stringValue, tags: tagsField.stringValue, sourceFile: audioField.stringValue)
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
        
        if let progressStack = progressStack, !progressStack.isHidden {
            if let pct = parseProgress(from: text) {
                progressBar?.doubleValue = pct
                progressLabel.stringValue = "\(Int(pct))%"
            }
        }
    }

    private func parseProgress(from text: String) -> Double? {
        let pattern = "progress\\s*=\\s*(\\d+)%"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        if let lastMatch = matches.last, lastMatch.numberOfRanges > 1 {
            let pctStr = nsString.substring(with: lastMatch.range(at: 1))
            return Double(pctStr)
        }
        return nil
    }

    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = "Whisper"
        a.informativeText = message
        a.runModal()
    }

    // MARK: - Browser tab methods

    private func buildBrowserTab() -> NSView {
        let tab = NSView()
        
        let chooseDirBtn = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseBrowserDir))
        chooseDirBtn.bezelStyle = .rounded
        chooseDirBtn.translatesAutoresizingMaskIntoConstraints = false
        
        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshBrowserDir))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        
        browserPathLabel.translatesAutoresizingMaskIntoConstraints = false
        browserPathLabel.font = NSFont.systemFont(ofSize: 11)
        browserPathLabel.textColor = .secondaryLabelColor
        
        let dirRow = NSStackView(views: [chooseDirBtn, refreshBtn, browserPathLabel])
        dirRow.orientation = .horizontal
        dirRow.alignment = .centerY
        dirRow.spacing = 8
        dirRow.distribution = .fill
        dirRow.translatesAutoresizingMaskIntoConstraints = false
        
        browserListView.orientation = .vertical
        browserListView.alignment = .width
        browserListView.spacing = 4
        browserListView.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        browserListView.translatesAutoresizingMaskIntoConstraints = false
        
        let listScroll = NSScrollView()
        let clipView = FlippedClipView()
        listScroll.contentView = clipView
        listScroll.documentView = browserListView
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = false
        listScroll.autohidesScrollers = true
        listScroll.borderType = .bezelBorder
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            browserListView.topAnchor.constraint(equalTo: clipView.topAnchor),
            browserListView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            browserListView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor)
        ])
        
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(dirRow)
        sidebar.addSubview(listScroll)
        
        NSLayoutConstraint.activate([
            dirRow.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 4),
            dirRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 4),
            dirRow.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -4),
            
            listScroll.topAnchor.constraint(equalTo: dirRow.bottomAnchor, constant: 6),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 4),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -4),
            listScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -4),
        ])
        
        browserCopyButton = NSButton(title: "Copy", target: self, action: #selector(copyBrowserContent))
        browserCopyButton.bezelStyle = .rounded
        browserCopyButton.isEnabled = false
        if #available(macOS 11.0, *) {
            browserCopyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            browserCopyButton.imagePosition = .imageLeft
        }
        
        browserOpenButton = NSButton(title: "Reveal in Finder", target: self, action: #selector(openBrowserFileInFinder))
        browserOpenButton.bezelStyle = .rounded
        browserOpenButton.isEnabled = false
        if #available(macOS 11.0, *) {
            browserOpenButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Reveal")
            browserOpenButton.imagePosition = .imageLeft
        }
        
        browserDeleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteBrowserFile))
        browserDeleteButton.bezelStyle = .rounded
        browserDeleteButton.isEnabled = false
        if #available(macOS 11.0, *) {
            browserDeleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            browserDeleteButton.imagePosition = .imageLeft
        }
        
        browserShareButton = NSButton(title: "Share…", target: self, action: #selector(shareClicked(_:)))
        browserShareButton.bezelStyle = .rounded
        browserShareButton.isEnabled = false
        if #available(macOS 11.0, *) {
            browserShareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
            browserShareButton.imagePosition = .imageLeft
        }
        
        browserRenameSpkButton = NSButton(title: "Rename Speaker…", target: self, action: #selector(renameSpeakerClicked))
        browserRenameSpkButton.bezelStyle = .rounded
        browserRenameSpkButton.isEnabled = false
        if #available(macOS 11.0, *) {
            browserRenameSpkButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Rename")
            browserRenameSpkButton.imagePosition = .imageLeft
        }
        
        let actionsRow = NSStackView(views: [browserCopyButton, browserOpenButton, browserShareButton, browserRenameSpkButton, browserDeleteButton])
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = 8
        actionsRow.translatesAutoresizingMaskIntoConstraints = false
        
        browserTextView.isEditable = false
        browserTextView.isRichText = false
        browserTextView.font = NSFont.systemFont(ofSize: 14)
        browserTextView.isVerticallyResizable = true
        browserTextView.isHorizontallyResizable = false
        browserTextView.autoresizingMask = [.width]
        browserTextView.textContainer?.widthTracksTextView = true
        browserTextView.delegate = self
        browserTextView.backgroundColor = NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)
        browserTextView.textColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)

        // Setup Browser Audio Sync Player UI
        browserPlayButton.title = "▶"
        browserPlayButton.bezelStyle = .rounded
        browserPlayButton.isEnabled = false
        browserPlayButton.target = self
        browserPlayButton.action = #selector(playPauseBrowserClicked)
        browserPlayButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        browserSlider.minValue = 0
        browserSlider.maxValue = 1
        browserSlider.doubleValue = 0
        browserSlider.target = self
        browserSlider.action = #selector(browserSliderDragged)
        browserSlider.isEnabled = false

        browserTimeLabel.isEditable = false
        browserTimeLabel.isBordered = false
        browserTimeLabel.backgroundColor = .clear
        browserTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        browserTimeLabel.textColor = .secondaryLabelColor
        browserTimeLabel.lineBreakMode = .byTruncatingTail

        let bPlayerInner = NSStackView(views: [browserPlayButton, browserSlider, browserTimeLabel])
        bPlayerInner.orientation = .horizontal
        bPlayerInner.spacing = 8
        bPlayerInner.alignment = .centerY
        bPlayerInner.distribution = .fill
        bPlayerInner.translatesAutoresizingMaskIntoConstraints = false

        let bPlayerRow = NSStackView(views: [bPlayerInner])
        bPlayerRow.orientation = .vertical
        bPlayerRow.alignment = .width
        bPlayerRow.translatesAutoresizingMaskIntoConstraints = false
        bPlayerRow.isHidden = false
        browserPlayerRow = bPlayerRow

        let contentScroll = makeScrollView(document: browserTextView)
        contentScroll.drawsBackground = true
        contentScroll.backgroundColor = NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)

        let contentPane = NSView()
        contentPane.translatesAutoresizingMaskIntoConstraints = false
        contentPane.addSubview(actionsRow)
        contentPane.addSubview(bPlayerRow)
        contentPane.addSubview(contentScroll)

        NSLayoutConstraint.activate([
            actionsRow.topAnchor.constraint(equalTo: contentPane.topAnchor, constant: 4),
            actionsRow.leadingAnchor.constraint(equalTo: contentPane.leadingAnchor, constant: 4),
            actionsRow.trailingAnchor.constraint(lessThanOrEqualTo: contentPane.trailingAnchor, constant: -4),

            bPlayerRow.topAnchor.constraint(equalTo: actionsRow.bottomAnchor, constant: 4),
            bPlayerRow.leadingAnchor.constraint(equalTo: contentPane.leadingAnchor, constant: 4),
            bPlayerRow.trailingAnchor.constraint(equalTo: contentPane.trailingAnchor, constant: -4),

            contentScroll.topAnchor.constraint(equalTo: bPlayerRow.bottomAnchor, constant: 6),
            contentScroll.leadingAnchor.constraint(equalTo: contentPane.leadingAnchor, constant: 4),
            contentScroll.trailingAnchor.constraint(equalTo: contentPane.trailingAnchor, constant: -4),
            contentScroll.bottomAnchor.constraint(equalTo: contentPane.bottomAnchor, constant: -4),
        ])
        
        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(contentPane)
        
        tab.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: tab.topAnchor, constant: 4),
            split.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 4),
            split.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -4),
            split.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -4),
        ])
        
        DispatchQueue.main.async {
            split.setPosition(250, ofDividerAt: 0)
        }
        
        return tab
    }

    private func refreshBrowserFiles() {
        let fm = FileManager.default
        let dir = selectedBrowserDir ?? (try? convertedOutputDirectory()) ?? fm.homeDirectoryForCurrentUser
        selectedBrowserDir = dir
        browserPathLabel.stringValue = dir.path
        browserPathLabel.lineBreakMode = .byTruncatingHead
        
        do {
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            browserFiles = files.filter { ["txt", "srt", "vtt"].contains($0.pathExtension.lowercased()) }
                .sorted { (url1, url2) -> Bool in
                    let d1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    let d2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    return d1 > d2
                }
        } catch {
            browserFiles = []
        }
        
        updateBrowserListView()
    }

    private func updateBrowserListView() {
        for subview in browserListView.arrangedSubviews {
            browserListView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        
        if browserFiles.isEmpty {
            let label = NSTextField(labelWithString: "No transcription files found")
            label.font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            browserListView.addArrangedSubview(label)
            return
        }
        
        for url in browserFiles {
            let filename = url.lastPathComponent
            
            let fm = FileManager.default
            var dateStr = ""
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let modDate = attrs[.modificationDate] as? Date {
                let fmt = DateFormatter()
                fmt.dateStyle = .short
                fmt.timeStyle = .short
                dateStr = fmt.string(from: modDate)
            }
            
            let btn = NSButton()
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.bezelStyle = .inline
            btn.title = filename + (dateStr.isEmpty ? "" : "  (\(dateStr))")
            btn.alignment = .left
            btn.font = NSFont.systemFont(ofSize: 12)
            btn.target = self
            btn.action = #selector(browserFileSelected(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(url.path)
            
            if url == browserSelectedURL {
                btn.state = .on
            } else {
                btn.state = .off
            }
            
            browserListView.addArrangedSubview(btn)
            
            NSLayoutConstraint.activate([
                btn.heightAnchor.constraint(equalToConstant: 24)
            ])
        }
        
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        browserListView.addArrangedSubview(spacer)
    }

    @objc private func browserFileSelected(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        let url = URL(fileURLWithPath: path)
        browserSelectedURL = url
        
        for subview in browserListView.arrangedSubviews {
            if let btn = subview as? NSButton {
                btn.state = (btn.identifier?.rawValue == path) ? .on : .off
            }
        }
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            browserTextView.string = content
            previousActiveRange = nil // Reset active range for new file
            applySpeakerColoringToBrowserText()
            browserDeleteButton.isEnabled = true
            browserOpenButton.isEnabled = true
            browserCopyButton.isEnabled = true
            browserShareButton.isEnabled = true
            browserRenameSpkButton.isEnabled = true
            setupBrowserPlayer(content: content)
        } catch {
            browserTextView.string = "Error loading file: \(error.localizedDescription)"
            browserDeleteButton.isEnabled = false
            browserOpenButton.isEnabled = false
            browserCopyButton.isEnabled = false
            browserShareButton.isEnabled = false
            browserRenameSpkButton.isEnabled = false
            disableBrowserPlayer()
        }
    }

    @objc private func chooseBrowserDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let dir = selectedBrowserDir {
            panel.directoryURL = dir
        }
        if panel.runModal() == .OK, let url = panel.url {
            selectedBrowserDir = url
            browserSelectedURL = nil
            browserTextView.string = ""
            browserDeleteButton.isEnabled = false
            browserOpenButton.isEnabled = false
            browserCopyButton.isEnabled = false
            browserShareButton.isEnabled = false
            browserRenameSpkButton.isEnabled = false
            disableBrowserPlayer()
            refreshBrowserFiles()
        }
    }

    @objc private func refreshBrowserDir() {
        refreshBrowserFiles()
    }

    @objc private func copyBrowserContent() {
        guard let url = browserSelectedURL else { return }
        let text = browserTextView.string
        if !text.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([text as NSString])
            statusLabel.stringValue = "Copied \(url.lastPathComponent) to clipboard."
        }
    }
    
    @objc private func shareClicked(_ sender: NSButton) {
        let text = browserTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let picker = NSSharingServicePicker(items: [text])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    
    @objc private func openBrowserFileInFinder() {
        guard let url = browserSelectedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    @objc private func renameSpeakerClicked() {
        guard let url = browserSelectedURL else { return }
        
        let content = browserTextView.string
        let lines = content.components(separatedBy: .newlines)
        
        var speakers = Set<String>()
        for line in lines {
            if let spk = extractSpeaker(from: line) {
                speakers.insert(spk)
            }
        }
        
        guard !speakers.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Rename Speaker"
            alert.informativeText = "No speakers found in this transcript to rename."
            alert.runModal()
            return
        }
        
        // Let user select old name
        let oldAlert = NSAlert()
        oldAlert.messageText = "Rename Speaker"
        oldAlert.informativeText = "Select speaker name to rename:"
        let oldCombo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        for spk in speakers.sorted() {
            oldCombo.addItem(withObjectValue: spk)
        }
        if !speakers.isEmpty {
            oldCombo.selectItem(at: 0)
        }
        oldAlert.accessoryView = oldCombo
        oldAlert.addButton(withTitle: "OK")
        oldAlert.addButton(withTitle: "Cancel")
        
        guard oldAlert.runModal() == .alertFirstButtonReturn else { return }
        let oldName = oldCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard speakers.contains(oldName) else {
            let errAlert = NSAlert()
            errAlert.messageText = "Error"
            errAlert.informativeText = "Speaker '\(oldName)' not found in transcript."
            errAlert.runModal()
            return
        }
        
        // Let user select new name/contact
        let newAlert = NSAlert()
        newAlert.messageText = "Rename Speaker"
        newAlert.informativeText = "Rename '\(oldName)' to:"
        let newCombo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        newCombo.completes = true
        let contacts = fetchContactsList()
        for c in contacts {
            newCombo.addItem(withObjectValue: c.name)
        }
        newAlert.accessoryView = newCombo
        newAlert.addButton(withTitle: "OK")
        newAlert.addButton(withTitle: "Cancel")
        
        guard newAlert.runModal() == .alertFirstButtonReturn else { return }
        var newName = newCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = newName.replacingOccurrences(of: "[^a-zA-Z0-9_\\- ]", with: "", options: .regularExpression)
        guard !newName.isEmpty else {
            let errAlert = NSAlert()
            errAlert.messageText = "Error"
            errAlert.informativeText = "Please enter a valid alphanumeric name."
            errAlert.runModal()
            return
        }
        
        let fm = FileManager.default
        let speakersDir = getSpeakersDirectory()
        
        let oldSigURL = speakersDir.appendingPathComponent("\(oldName).sig")
        let newSigURL = speakersDir.appendingPathComponent("\(newName).sig")
        
        if fm.fileExists(atPath: oldSigURL.path) {
            do {
                if fm.fileExists(atPath: newSigURL.path) {
                    let mergeAlert = NSAlert()
                    mergeAlert.messageText = "Merge Speaker"
                    mergeAlert.informativeText = "Speaker '\(newName)' already exists. Overwrite?"
                    mergeAlert.addButton(withTitle: "Yes")
                    mergeAlert.addButton(withTitle: "No")
                    if mergeAlert.runModal() != .alertFirstButtonReturn {
                        return
                    }
                    try? fm.removeItem(at: newSigURL)
                }
                try fm.moveItem(at: oldSigURL, to: newSigURL)
            } catch {
                let errAlert = NSAlert()
                errAlert.messageText = "Error"
                errAlert.informativeText = "Failed to rename signature: \(error.localizedDescription)"
                errAlert.runModal()
                return
            }
        }
        
        // Replace in transcript
        var newLines = [String]()
        for line in lines {
            if line.hasPrefix("\(oldName): ") {
                let updated = line.replacingOccurrences(of: "\(oldName): ", with: "\(newName): ")
                newLines.append(updated)
            } else {
                newLines.append(line)
            }
        }
        
        let newContent = newLines.joined(separator: "\n")
        do {
            try newContent.write(to: url, atomically: true, encoding: .utf8)
            browserTextView.string = newContent
            applySpeakerColoringToBrowserText()
            refreshSpeakersList()
            parseTimestampsInBrowserText(newContent)
            
            let successAlert = NSAlert()
            successAlert.messageText = "Success"
            successAlert.informativeText = "Speaker '\(oldName)' successfully renamed to '\(newName)'!"
            successAlert.runModal()
        } catch {
            let errAlert = NSAlert()
            errAlert.messageText = "Error"
            errAlert.informativeText = "Failed to save transcript: \(error.localizedDescription)"
            errAlert.runModal()
        }
    }
    
    @objc private func deleteBrowserFile() {
        guard let url = browserSelectedURL else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Transcription File?"
        alert.informativeText = "Are you sure you want to permanently delete \(url.lastPathComponent)?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try FileManager.default.removeItem(at: url)
                browserSelectedURL = nil
                browserTextView.string = ""
                browserDeleteButton.isEnabled = false
                browserOpenButton.isEnabled = false
                browserCopyButton.isEnabled = false
                browserShareButton.isEnabled = false
                browserRenameSpkButton.isEnabled = false
                disableBrowserPlayer()
                refreshBrowserFiles()
            } catch {
                self.alert("Failed to delete file:\n\(error.localizedDescription)")
            }
        }
    }

    private func startGlowAnimation() {
        transcribeButton.layer?.masksToBounds = false
        transcribeButton.layer?.shadowColor = NSColor.controlAccentColor.cgColor
        transcribeButton.layer?.shadowOpacity = 0.95
        transcribeButton.layer?.shadowRadius = 16
        transcribeButton.layer?.shadowOffset = CGSize(width: 0, height: 0)
        
        let opacityPulse = CABasicAnimation(keyPath: "shadowOpacity")
        opacityPulse.fromValue = 0.4
        opacityPulse.toValue = 0.98
        opacityPulse.duration = 0.8
        opacityPulse.repeatCount = .infinity
        opacityPulse.autoreverses = true
        opacityPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        transcribeButton.layer?.add(opacityPulse, forKey: "glowPulse")
        
        let radiusPulse = CABasicAnimation(keyPath: "shadowRadius")
        radiusPulse.fromValue = 4.0
        radiusPulse.toValue = 28.0
        radiusPulse.duration = 0.8
        radiusPulse.repeatCount = .infinity
        radiusPulse.autoreverses = true
        radiusPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        transcribeButton.layer?.add(radiusPulse, forKey: "radiusPulse")
        
        let colorPulse = CABasicAnimation(keyPath: "backgroundColor")
        let baseColor = NSColor.controlAccentColor.cgColor
        let brightColor = NSColor.systemPurple.cgColor
        colorPulse.fromValue = baseColor
        colorPulse.toValue = brightColor
        colorPulse.duration = 0.8
        colorPulse.repeatCount = .infinity
        colorPulse.autoreverses = true
        colorPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        transcribeButton.layer?.add(colorPulse, forKey: "colorPulse")
        
        // Add a pulsing glowing border
        transcribeButton.layer?.borderWidth = 1.5
        transcribeButton.layer?.borderColor = NSColor.controlAccentColor.cgColor
        
        let borderPulse = CABasicAnimation(keyPath: "borderColor")
        borderPulse.fromValue = NSColor.controlAccentColor.cgColor
        borderPulse.toValue = NSColor.systemPurple.cgColor
        borderPulse.duration = 0.8
        borderPulse.repeatCount = .infinity
        borderPulse.autoreverses = true
        borderPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        transcribeButton.layer?.add(borderPulse, forKey: "borderPulse")
    }
    
    private func stopGlowAnimation() {
        transcribeButton.layer?.removeAnimation(forKey: "glowPulse")
        transcribeButton.layer?.removeAnimation(forKey: "radiusPulse")
        transcribeButton.layer?.removeAnimation(forKey: "colorPulse")
        transcribeButton.layer?.removeAnimation(forKey: "borderPulse")
        transcribeButton.layer?.shadowOpacity = 0.0
        transcribeButton.layer?.borderWidth = 0.0
        transcribeButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }
    
    private func setTranscribingState(active: Bool, title: String = "Transcribe") {
        isTranscribing = active
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Invalidate any active spinner timer
            self.transcribeTimer?.invalidate()
            self.transcribeTimer = nil
            
            if active {
                self.startGlowAnimation()
                self.transcribeSpinnerIndex = 0
                let spinners = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
                
                self.transcribeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    let spinner = spinners[self.transcribeSpinnerIndex % spinners.count]
                    self.transcribeSpinnerIndex += 1
                    
                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.alignment = .center
                    let attrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.white,
                        .font: NSFont.boldSystemFont(ofSize: 13),
                        .paragraphStyle: paragraphStyle
                    ]
                    self.transcribeButton.attributedTitle = NSAttributedString(string: "  " + spinner + " " + title, attributes: attrs)
                }
            } else {
                self.stopGlowAnimation()
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .paragraphStyle: paragraphStyle
                ]
                self.transcribeButton.attributedTitle = NSAttributedString(string: "  " + title, attributes: attrs)
            }
        }
    }
}

extension WhisperApp: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField else { return }
        if textField === tagsField {
            let text = textField.stringValue
            guard let editor = textField.currentEditor() else { return }
            let cursorPosition = editor.selectedRange.location
            
            let prefix = String(text.prefix(cursorPosition))
            let parts = prefix.components(separatedBy: ",")
            guard let lastPart = parts.last else { return }
            let trimmedPart = lastPart.trimmingCharacters(in: .whitespaces)
            guard !trimmedPart.isEmpty else { return }
            
            if let match = tagOptions.first(where: { $0.lowercased().hasPrefix(trimmedPart.lowercased()) }) {
                let suffix = String(match.dropFirst(trimmedPart.count))
                guard !suffix.isEmpty else { return }
                
                var newParts = parts
                newParts[newParts.count - 1] = lastPart + suffix
                let completedText = newParts.joined(separator: ",") + String(text.suffix(text.count - cursorPosition))
                
                textField.stringValue = completedText
                editor.selectedRange = NSRange(location: cursorPosition, length: suffix.count)
            }
        }
    }
}

extension WhisperApp: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if player === self.previewPlayer {
                self.previewPlayButton.title = "▶"
                self.previewSlider.doubleValue = 0
                self.stopPreviewTimer()
                self.updatePreviewTimeLabel()
            } else if player === self.browserPlayer {
                self.browserPlayButton.title = "▶"
                self.browserSlider.doubleValue = 0
                self.stopBrowserTimer()
                self.updateBrowserTimeLabel()
            }
        }
    }
}

extension WhisperApp: NSTextViewDelegate {
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if textView === browserTextView {
            let selectedRange = textView.selectedRange()
            guard selectedRange.length == 0 else { return }
            
            let loc = selectedRange.location
            if let matched = timestampRanges.first(where: { loc >= $0.range.location && loc <= ($0.range.location + $0.range.length) }) {
                if let player = browserPlayer {
                    player.currentTime = matched.start
                    browserSlider.doubleValue = matched.start
                    updateBrowserTimeLabel()
                    highlightActiveTimestampLine()
                }
            }
        }
    }
}

extension WhisperApp: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if tabViewItem?.identifier as? String == "browser" {
            refreshBrowserFiles()
        }
    }
}

let app = NSApplication.shared
let delegate = WhisperApp()
app.delegate = delegate
app.run()
