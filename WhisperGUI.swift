import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers
import AVFoundation
import Contacts

// MARK: - Models and Settings

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

// MARK: - App State Model

final class AppModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var settings = SettingsStore.load() {
        didSet {
            SettingsStore.save(settings)
        }
    }

    // Transcription settings & states
    @Published var audioPath: String = "" {
        didSet {
            if !audioPath.isEmpty {
                setupPreviewPlayer(path: audioPath)
            }
        }
    }
    @Published var modelPath: String = ""
    @Published var customName: String = ""
    @Published var noteName: String = ""
    @Published var tags: String = ""
    @Published var isTranscribing: Bool = false
    @Published var statusText: String = "Idle"
    @Published var progressValue: Double = 0.0
    @Published var progressPercent: String = "0%"
    @Published var consoleLogs: String = ""
    @Published var transcriptText: String = ""
    @Published var registeredSpeakers: String = "None registered"
    
    // Tag choices
    @Published var availableTags: [String] = ["meeting", "conference", "bank", "lecture", "interview", "podcast"]

    // Preview Audio Player state
    @Published var previewPlaybackTime: Double = 0.0
    @Published var previewPlaybackDuration: Double = 0.0
    @Published var previewIsPlaying: Bool = false
    private var previewPlayer: AVAudioPlayer?
    private var previewTimer: Timer?

    // Browser tab state
    @Published var selectedBrowserDir: URL?
    @Published var browserFiles: [URL] = []
    @Published var selectedBrowserURL: URL?
    @Published var browserTextContent: String = ""
    @Published var browserPlaybackTime: Double = 0.0
    @Published var browserPlaybackDuration: Double = 0.0
    @Published var browserIsPlaying: Bool = false
    @Published var highlightedRange: NSRange?
    @Published var browserAudioURL: URL?
    @Published var dependencyCheckStatus: String = ""
    
    // Contacts & Autocomplete
    @Published var contacts: [String] = []
    
    // Diagnostics Output
    @Published var diagnosticsReport: String = ""
    @Published var isCheckingDiagnostics: Bool = false

    // App alert state
    @Published var showAlert: Bool = false
    @Published var alertTitle: String = ""
    @Published var alertMessage: String = ""

    private var process: Process?
    private var readSource: DispatchSourceRead?
    private var convertedPath: String?
    private var originalSourcePath: String?

    // Browser player fields
    private var browserPlayer: AVAudioPlayer?
    private var browserTimer: Timer?
    var timestampRanges: [(start: Double, end: Double, range: NSRange)] = []

    private static let whisperNativeExts: Set<String> = ["wav", "mp3", "flac", "ogg"]
    private static let convertExts: Set<String> = [
        "m4a", "qta", "mp4", "mov", "mkv", "webm", "aac", "caf", "m4v", "avi", "wmv",
    ]
    
    private static let voiceMemosDirectories: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings"),
    ]

    override init() {
        super.init()
        setupDefaultPaths()
        loadBrowserDirectory()
        loadContacts()
        refreshSpeakersList()
    }

    private func setupDefaultPaths() {
        let fm = FileManager.default
        let homeDir = NSHomeDirectory()
        let defaultModel = homeDir + "/whisper-medium.bin"
        if fm.fileExists(atPath: defaultModel) {
            modelPath = defaultModel
        }
        let defaultAudio = homeDir + "/input_ready.wav"
        if fm.fileExists(atPath: defaultAudio) {
            audioPath = defaultAudio
        }
    }

    func showSystemAlert(title: String, message: String) {
        DispatchQueue.main.async {
            self.alertTitle = title
            self.alertMessage = message
            self.showAlert = true
        }
    }

    // MARK: - Picker Actions

    func pickAudio(fromDirectory directory: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = directory == nil ? "Choose audio or video" : "Choose a Voice Memo (.m4a)"
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
            prepareAudio(from: url)
        }
    }

    func pickModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Whisper model (.bin)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url {
            modelPath = url.path
        }
    }

    func pickFfmpeg() {
        let panel = NSOpenPanel()
        panel.title = "Choose ffmpeg binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.ffmpegPath = url.path
        }
    }

    func pickCli() {
        let panel = NSOpenPanel()
        panel.title = "Choose whisper-cli binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.cliPath = url.path
        }
    }

    func pickObsidianVault() {
        let panel = NSOpenPanel()
        panel.title = "Choose Obsidian Vault Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.obsidianVaultPath = url.path
        }
    }

    func chooseBrowserDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Converted Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedBrowserDir = url
            loadBrowserDirectory()
        }
    }

    func pickVoiceMemos() {
        guard let folder = voiceMemosFolder() else { return }
        if !FileManager.default.fileExists(atPath: folder.path) {
            showSystemAlert(
                title: "Voice Memos",
                message: "Voice Memos folder not found yet.\n\nExport from the Voice Memos app:\n• Select memo → Share (⋯) → Save to Downloads\n• Or drag it here."
            )
            return
        }
        pickAudio(fromDirectory: folder)
    }

    private func voiceMemosFolder() -> URL? {
        for url in Self.voiceMemosDirectories {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return Self.voiceMemosDirectories.first
    }

    func handleDroppedFile(_ url: URL) {
        prepareAudio(from: url)
    }

    private func prepareAudio(from url: URL) {
        originalSourcePath = url.path
        audioPath = url.path
        
        let stem = url.deletingPathExtension().lastPathComponent
        customName = stem
        noteName = stem
    }

    // MARK: - Core Processing Logic

    private func needsConversion(_ path: String) -> Bool {
        if settings.forceConvert { return true }
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.whisperNativeExts.contains(ext) { return false }
        if Self.convertExts.contains(ext) { return true }
        return true
    }

    private func convertedOutputPath(for sourcePath: String) throws -> String {
        let fm = FileManager.default
        let outDir = try convertedOutputDirectory()
        let sourceStem = URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        
        var outPath = outDir.appendingPathComponent(sourceStem + ".wav").path
        var counter = 1
        while fm.fileExists(atPath: outPath) {
            outPath = outDir.appendingPathComponent("\(sourceStem)-\(counter).wav").path
            counter += 1
        }
        return outPath
    }

    private func convertedOutputDirectory() throws -> URL {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "WhisperGUI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Application Support not found"])
        }
        let dir = appSupport.appendingPathComponent("whisper-gui/converted")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func resolveAudioPath(_ path: String) throws -> String {
        if !needsConversion(path) {
            appendLog("Using native format: \((path as NSString).lastPathComponent)\n")
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
        appendLog("Converting with ffmpeg…\n  in:  \(path)\n  out: \(outPath)\n\n")

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
        if !errOut.isEmpty { appendLog(errOut + "\n") }

        guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: outPath) else {
            let tail = errOut.split(separator: "\n").suffix(8).joined(separator: "\n")
            var msg = "ffmpeg failed (exit \(proc.terminationStatus))."
            if !tail.isEmpty { msg += "\n\n\(tail)" }
            throw NSError(domain: "WhisperGUI", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        convertedPath = outPath
        appendLog("Conversion done.\n\n")
        return outPath
    }

    func runTranscribe() {
        guard !isTranscribing else { return }
        let audio = audioPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cli = settings.cliPath

        guard !audio.isEmpty else {
            showSystemAlert(title: "Whisper", message: "Drop a file or click Choose… first.")
            return
        }
        if originalSourcePath == nil {
            originalSourcePath = audio
        }
        guard FileManager.default.fileExists(atPath: audio) else {
            showSystemAlert(title: "Whisper", message: "Audio file not found:\n\(audio)")
            return
        }
        guard FileManager.default.fileExists(atPath: cli) else {
            showSystemAlert(title: "Whisper", message: "whisper-cli not found at:\n\(cli)\n\nInstall: brew install whisper-cpp")
            return
        }
        guard FileManager.default.fileExists(atPath: model) else {
            showSystemAlert(title: "Whisper", message: "Model not found:\n\(model)")
            return
        }

        stopProcess()
        isTranscribing = true
        statusText = "Preparing…"
        progressValue = 0.0
        progressPercent = "0%"
        consoleLogs = ""
        transcriptText = ""

        let sourceURL = URL(fileURLWithPath: audio)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                let ready = try self.resolveAudioPath(audio)
                DispatchQueue.main.async {
                    self.audioPath = ready
                    self.startWhisper(audio: ready, model: model)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isTranscribing = false
                    self.statusText = "Preparation failed."
                    self.showSystemAlert(title: "Error", message: error.localizedDescription)
                }
            }
        }
    }

    private func startWhisper(audio: String, model: String) {
        statusText = "Transcribing…"
        
        let customNameTrimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem: String
        if !customNameTrimmed.isEmpty {
            let dir = (audio as NSString).deletingLastPathComponent
            stem = (dir as NSString).appendingPathComponent(customNameTrimmed)
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
            isTranscribing = false
            showSystemAlert(title: "Error", message: "Failed to start whisper-cli:\n\(error.localizedDescription)")
        }
    }

    func stopProcess() {
        readSource?.cancel()
        readSource = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        isTranscribing = false
    }

    private func onFinished(exitCode: Int32, audioStem: String) {
        if exitCode == 0 && settings.diarizeEnabled {
            runDiarizationAndProceed(audioStem: audioStem, audioPath: audioPath, exitCode: exitCode)
        } else {
            onFinishedProceed(exitCode: exitCode, audioStem: audioStem)
        }
    }

    private func onFinishedProceed(exitCode: Int32, audioStem: String) {
        readSource?.cancel()
        readSource = nil
        process = nil
        isTranscribing = false

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
                    transcriptText = updatedText
                    noteText = text
                } else {
                    transcriptText = text
                    if let separatorRange = text.range(of: "----------------------------------------\n\n\n") {
                        noteText = String(text[separatorRange.upperBound...])
                    } else {
                        noteText = text
                    }
                }
            } else {
                transcriptText = header + text
                noteText = text
            }
            statusText = "Done — saved \(URL(fileURLWithPath: found).lastPathComponent)"
            saveToObsidian(text: noteText, noteName: noteName, tags: tags, sourceFile: audioPath)
        } else if exitCode == 0, let fallback = extractTranscriptFromLog() {
            transcriptText = header + fallback
            statusText = "Done (from log)."
            saveToObsidian(text: fallback, noteName: noteName, tags: tags, sourceFile: audioPath)
        } else if exitCode == 0 {
            statusText = "Done (check logs)."
        } else {
            statusText = "Failed (exit \(exitCode))."
            var msg = "whisper-cli exited with code \(exitCode)."
            if (exitCode == 139 || exitCode == 11) && settings.useGpu {
                msg += "\n\nTry disabling GPU acceleration."
            }
            showSystemAlert(title: "Transcription Failed", message: msg)
        }
        
        loadBrowserDirectory()
    }

    // MARK: - Post-Processing & Sync Helpers

    private func makeTranscriptHeader() -> String {
        let path = originalSourcePath ?? (audioPath.isEmpty ? nil : audioPath)
        guard let p = path, FileManager.default.fileExists(atPath: p) else { return "" }
        let filename = URL(fileURLWithPath: p).lastPathComponent
        
        var dateStr = "Unknown"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: p) {
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
        let note = noteName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { header += "Note: \(note)\n" }
        let customTitle = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customTitle.isEmpty { header += "Title: \(customTitle)\n" }
        let selectedTags = tags.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedTags.isEmpty { header += "Tags: \(selectedTags)\n" }
        header += "Created: \(dateStr)\n"
        header += "----------------------------------------\n\n\n"
        return header
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
        var lines: [String] = []
        for line in consoleLogs.split(separator: "\n", omittingEmptySubsequences: false) {
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
        DispatchQueue.main.async {
            self.consoleLogs += text
            if let pct = self.parseProgress(from: text) {
                self.progressValue = pct
                self.progressPercent = "\(Int(pct))%"
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
        content += "created: \(isoFormatter.string(from: Date()))\n"
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

    // MARK: - Diarization Logic

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
        
        statusText = "Running speaker diarization..."
        
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

    private func extractTimestampedTranscriptFromLog() -> String {
        var lines: [String] = []
        let pat = "\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\s*-+>\\s*\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\]"
        let patShort = "\\[\\d{2}:\\d{2}\\.\\d{3}\\s*-+>\\s*\\d{2}:\\d{2}\\.\\d{3}\\]"
        guard let reg = try? NSRegularExpression(pattern: pat, options: []),
              let regShort = try? NSRegularExpression(pattern: patShort, options: []) else {
            return ""
        }
        
        for line in consoleLogs.split(separator: "\n", omittingEmptySubsequences: false) {
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

    // MARK: - Speaker Signature Utilities

    func getSpeakersDirectory() -> URL {
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
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        
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

    func refreshSpeakersList() {
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
            
            DispatchQueue.main.async {
                if !sigs.isEmpty {
                    self.registeredSpeakers = "Registered: " + sigs.sorted().joined(separator: ", ")
                } else {
                    self.registeredSpeakers = "None registered"
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.registeredSpeakers = "None registered"
            }
        }
    }

    func registerVoice(label: String, filePath: String, completion: @escaping (Bool, String) -> Void) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath) else {
            completion(false, "Audio sample file not found at: \(filePath)")
            return
        }
        let cleanedLabel = label.replacingOccurrences(of: "[^a-zA-Z0-9_\\- ]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedLabel.isEmpty else {
            completion(false, "Please enter a valid speaker label.")
            return
        }
        
        var enginePath = "/Users/dfe/whisper-gui/speaker_engine.py"
        if !fm.fileExists(atPath: enginePath) {
            if let resourcePath = Bundle.main.path(forResource: "speaker_engine", ofType: "py") {
                enginePath = resourcePath
            } else {
                enginePath = fm.currentDirectoryPath + "/speaker_engine.py"
            }
        }
        
        guard fm.fileExists(atPath: enginePath) else {
            completion(false, "speaker_engine.py not found.")
            return
        }
        
        var pythonPath = "/usr/bin/python3"
        if fm.fileExists(atPath: "/opt/homebrew/bin/python3") {
            pythonPath = "/opt/homebrew/bin/python3"
        } else if fm.fileExists(atPath: "/usr/local/bin/python3") {
            pythonPath = "/usr/local/bin/python3"
        }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [enginePath, "--learn", cleanedLabel, filePath]
        
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        proc.environment = env
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        proc.terminationHandler = { [weak self] p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self?.refreshSpeakersList()
                if p.terminationStatus == 0 {
                    completion(true, "Successfully registered speaker '\(cleanedLabel)'!")
                } else {
                    let errMsg = output.isEmpty ? "Process exited with code \(p.terminationStatus)" : output
                    completion(false, "Failed: \(errMsg)")
                }
            }
        }
        
        do {
            try proc.run()
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    func renameSpeaker(oldName: String, newName: String, fileURL: URL) -> String? {
        let cleanedNewName = newName.replacingOccurrences(of: "[^a-zA-Z0-9_\\- ]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedNewName.isEmpty else { return "Please enter a valid alphanumeric name." }
        
        let fm = FileManager.default
        let speakersDir = getSpeakersDirectory()
        
        let oldSigURL = speakersDir.appendingPathComponent("\(oldName).sig")
        let newSigURL = speakersDir.appendingPathComponent("\(cleanedNewName).sig")
        
        if fm.fileExists(atPath: oldSigURL.path) {
            do {
                if fm.fileExists(atPath: newSigURL.path) {
                    try? fm.removeItem(at: newSigURL)
                }
                try fm.moveItem(at: oldSigURL, to: newSigURL)
            } catch {
                return "Failed to rename signature: \(error.localizedDescription)"
            }
        }
        
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return "Failed to read transcript file."
        }
        
        let lines = content.components(separatedBy: .newlines)
        var newLines = [String]()
        for line in lines {
            if line.hasPrefix("\(oldName): ") {
                let updated = line.replacingOccurrences(of: "\(oldName): ", with: "\(cleanedNewName): ")
                newLines.append(updated)
            } else {
                newLines.append(line)
            }
        }
        
        let newContent = newLines.joined(separator: "\n")
        do {
            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
            self.browserTextContent = newContent
            self.refreshSpeakersList()
            self.parseTimestampsInBrowserText(newContent)
            return nil
        } catch {
            return "Failed to save transcript: \(error.localizedDescription)"
        }
    }

    // MARK: - Browser Selection & Playback

    func loadBrowserDirectory() {
        let fm = FileManager.default
        let dir: URL
        if let customDir = selectedBrowserDir {
            dir = customDir
        } else {
            guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            dir = appSupport.appendingPathComponent("whisper-gui/converted")
        }
        
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        
        do {
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            let sorted = files.filter {
                ["txt", "srt", "vtt", "json"].contains($0.pathExtension.lowercased())
            }.sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return d1 > d2
            }
            DispatchQueue.main.async {
                self.browserFiles = sorted
            }
        } catch {
            print("Failed to scan browser files: \(error)")
        }
    }

    func selectBrowserFile(url: URL) {
        selectedBrowserURL = url
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            browserTextContent = "Failed to load content."
            return
        }
        browserTextContent = content
        stopBrowserPlayer()

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
            browserAudioURL = nil
            timestampRanges.removeAll()
            return
        }

        let fileURL = URL(fileURLWithPath: path)
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.prepareToPlay()
            browserPlayer = player
            browserAudioURL = fileURL
            
            browserPlaybackDuration = player.duration
            browserPlaybackTime = 0.0
            browserIsPlaying = false
            
            parseTimestampsInBrowserText(content)
        } catch {
            appendLog("Could not initialize browser audio player: \(error.localizedDescription)\n")
        }
    }

    func playPauseBrowser() {
        guard let player = browserPlayer else { return }
        if player.isPlaying {
            player.pause()
            browserIsPlaying = false
            stopBrowserTimer()
        } else {
            player.play()
            browserIsPlaying = true
            startBrowserTimer()
        }
    }

    func seekBrowser(time: Double) {
        guard let player = browserPlayer else { return }
        player.currentTime = time
        browserPlaybackTime = time
        highlightActiveTimestampLine()
    }

    func stopBrowserPlayer() {
        browserPlayer?.stop()
        browserIsPlaying = false
        browserPlaybackTime = 0.0
        stopBrowserTimer()
    }

    private func startBrowserTimer() {
        stopBrowserTimer()
        browserTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.browserPlayer else { return }
            DispatchQueue.main.async {
                self.browserPlaybackTime = player.currentTime
                self.highlightActiveTimestampLine()
                if !player.isPlaying {
                    self.browserIsPlaying = false
                    self.stopBrowserTimer()
                }
            }
        }
    }

    private func stopBrowserTimer() {
        browserTimer?.invalidate()
        browserTimer = nil
    }

    private func highlightActiveTimestampLine() {
        let time = browserPlaybackTime
        guard let matched = timestampRanges.first(where: { time >= $0.start && time <= $0.end }) else {
            return
        }
        highlightedRange = matched.range
    }

    // MARK: - Transcribe Preview Player

    func setupPreviewPlayer(path: String) {
        stopPreviewPlayer()
        let fileURL = URL(fileURLWithPath: path)
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.prepareToPlay()
            previewPlayer = player
            previewPlaybackDuration = player.duration
            previewPlaybackTime = 0.0
            previewIsPlaying = false
        } catch {
            print("Preview player init failed: \(error)")
        }
    }

    func playPausePreview() {
        guard let player = previewPlayer else { return }
        if player.isPlaying {
            player.pause()
            previewIsPlaying = false
            stopPreviewTimer()
        } else {
            player.play()
            previewIsPlaying = true
            startPreviewTimer()
        }
    }

    func seekPreview(time: Double) {
        guard let player = previewPlayer else { return }
        player.currentTime = time
        previewPlaybackTime = time
    }

    func stopPreviewPlayer() {
        previewPlayer?.stop()
        previewIsPlaying = false
        previewPlaybackTime = 0.0
        stopPreviewTimer()
    }

    private func startPreviewTimer() {
        stopPreviewTimer()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.previewPlayer else { return }
            DispatchQueue.main.async {
                self.previewPlaybackTime = player.currentTime
                if !player.isPlaying {
                    self.previewIsPlaying = false
                    self.stopPreviewTimer()
                }
            }
        }
    }

    private func stopPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    // MARK: - Timestamp Parsers

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
            
            // Log pattern
            if let m = regLog.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) {
                if m.numberOfRanges > 2 {
                    let startMin = (line as NSString).substring(with: m.range(at: 1))
                    let startSec = (line as NSString).substring(with: m.range(at: 2))
                    var startMs: String?
                    if m.range(at: 3).location != NSNotFound {
                        startMs = (line as NSString).substring(with: m.range(at: 3))
                    }
                    let start = parseTimeValue(mins: startMin, secs: startSec, ms: startMs)
                    
                    var end = start + 3.0
                    if m.numberOfRanges > 5, m.range(at: 4).location != NSNotFound, m.range(at: 5).location != NSNotFound {
                        let endMin = (line as NSString).substring(with: m.range(at: 4))
                        let endSec = (line as NSString).substring(with: m.range(at: 5))
                        var endMs: String?
                        if m.range(at: 6).location != NSNotFound {
                            endMs = (line as NSString).substring(with: m.range(at: 6))
                        }
                        end = parseTimeValue(mins: endMin, secs: endSec, ms: endMs)
                    }
                    timestampRanges.append((start: start, end: end, range: lineRange))
                }
            }
            // SRT pattern
            else if let m = regSrt.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) {
                if m.numberOfRanges > 8 {
                    let sHr = Double((line as NSString).substring(with: m.range(at: 1))) ?? 0
                    let sMin = Double((line as NSString).substring(with: m.range(at: 2))) ?? 0
                    let sSec = Double((line as NSString).substring(with: m.range(at: 3))) ?? 0
                    let sMs = Double((line as NSString).substring(with: m.range(at: 4))) ?? 0
                    let start = sHr * 3600.0 + sMin * 60.0 + sSec + sMs * 0.001
                    
                    let eHr = Double((line as NSString).substring(with: m.range(at: 5))) ?? 0
                    let eMin = Double((line as NSString).substring(with: m.range(at: 6))) ?? 0
                    let eSec = Double((line as NSString).substring(with: m.range(at: 7))) ?? 0
                    let eMs = Double((line as NSString).substring(with: m.range(at: 8))) ?? 0
                    let end = eHr * 3600.0 + eMin * 60.0 + eSec + eMs * 0.001
                    
                    timestampRanges.append((start: start, end: end, range: lineRange))
                }
            }
            // VTT Short pattern
            else if let m = regVttShort.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) {
                if m.numberOfRanges > 6 {
                    let sMin = Double((line as NSString).substring(with: m.range(at: 1))) ?? 0
                    let sSec = Double((line as NSString).substring(with: m.range(at: 2))) ?? 0
                    let sMs = Double((line as NSString).substring(with: m.range(at: 3))) ?? 0
                    let start = sMin * 60.0 + sSec + sMs * 0.001
                    
                    let eMin = Double((line as NSString).substring(with: m.range(at: 4))) ?? 0
                    let eSec = Double((line as NSString).substring(with: m.range(at: 5))) ?? 0
                    let eMs = Double((line as NSString).substring(with: m.range(at: 6))) ?? 0
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

    func getSpeakerColors(for speaker: String?) -> (bg: NSColor, active: NSColor) {
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

    func extractSpeaker(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        let lowerTrimmed = trimmed.lowercased()
        for prefix in ["file:", "path:", "tags:", "created:", "note:", "title:", "source_file:", "---"] {
            if lowerTrimmed.hasPrefix(prefix) { return nil }
        }
        
        guard let colonRange = trimmed.range(of: ":") else { return nil }
        let speakerPart = String(trimmed[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if speakerPart.count > 0 && speakerPart.count < 30 {
            let invalidChars = CharacterSet(charactersIn: "[]<>-")
            if speakerPart.rangeOfCharacter(from: invalidChars) == nil {
                if Int(speakerPart) == nil { return speakerPart }
            }
        }
        return nil
    }

    // MARK: - Autocomplete and Address Book Loader

    func loadContacts() {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        
        var list: [String] = []
        if status == .authorized {
            try? store.enumerateContacts(with: request) { contact, _ in
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespacesAndNewlines)
                if !fullName.isEmpty {
                    list.append(fullName)
                }
            }
        }
        DispatchQueue.main.async {
            self.contacts = list.sorted()
        }
    }

    func requestContactsPermissionAndReload() {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            store.requestAccess(for: .contacts) { [weak self] granted, _ in
                if granted {
                    DispatchQueue.main.async {
                        self?.loadContacts()
                    }
                }
            }
        } else {
            loadContacts()
        }
    }

    // MARK: - Diagnostics and Update Checks

    func checkWhisperUpdate() {
        dependencyCheckStatus = "Checking Whisper Update..."
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
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        proc.environment = env
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "No output."
                self?.showSystemAlert(title: "Whisper Update Check", message: output.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                self?.showSystemAlert(title: "Update Check Failed", message: "brew error: \(error.localizedDescription)")
            }
        }
    }

    func checkSherpaUpdate() {
        dependencyCheckStatus = "Checking Sherpa Update..."
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
    print("sherpa-onnx is not installed. Run 'pip3 install sherpa-onnx --break-system-packages'")
    sys.exit(0)
try:
    req = urllib.request.Request('https://pypi.org/pypi/sherpa-onnx/json', headers={'User-Agent': 'Mozilla/5.0'})
    latest = json.loads(urllib.request.urlopen(req, timeout=5).read().decode())['info']['version']
    if curr == latest:
        print(f"sherpa-onnx is up-to-date ({curr}).")
    else:
        print(f"Update available!\\nInstalled: {curr}\\nLatest: {latest}\\n\\nUpgrade: pip3 install sherpa-onnx --upgrade --break-system-packages")
except Exception as e:
    print(f"Installed: {curr}\\nPyPI check failed: {e}")
"""]
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "No output."
                self?.showSystemAlert(title: "Sherpa-ONNX Update Check", message: output.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                self?.showSystemAlert(title: "Update Check Failed", message: "Python error: \(error.localizedDescription)")
            }
        }
    }

    func checkDependencies() {
        isCheckingDiagnostics = true
        diagnosticsReport = "Running diagnostic checks...\n"
        
        let fm = FileManager.default
        var report = "=== DEPENDENCY DIAGNOSTICS ===\n\n"
        report += "● Whisper GUI Version: 1.2.0 (SwiftUI Native)\n\n"
        
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
        
        report += resolvedBrew != nil ? "✔ Homebrew: Found at \(resolvedBrew!)\n" : "✘ Homebrew: Not found in PATH\n"
        report += fm.fileExists(atPath: settings.ffmpegPath) ? "✔ ffmpeg: Found at \(settings.ffmpegPath)\n" : "✘ ffmpeg: Not found\n"
        report += fm.fileExists(atPath: settings.cliPath) ? "✔ whisper-cli: Found at \(settings.cliPath)\n" : "✘ whisper-cli: Not found\n"
        
        var pythonPath = "/usr/bin/python3"
        if fm.fileExists(atPath: "/opt/homebrew/bin/python3") {
            pythonPath = "/opt/homebrew/bin/python3"
        }
        
        if fm.fileExists(atPath: pythonPath) {
            report += "✔ Python 3: Found at \(pythonPath)\n"
            let sherpaProc = Process()
            sherpaProc.executableURL = URL(fileURLWithPath: pythonPath)
            sherpaProc.arguments = ["-c", "import sherpa_onnx; print(sherpa_onnx.__version__)"]
            let pipe = Pipe()
            sherpaProc.standardOutput = pipe
            sherpaProc.standardError = Pipe()
            do {
                try sherpaProc.run()
                sherpaProc.waitUntilExit()
                if sherpaProc.terminationStatus == 0 {
                    let version = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    report += "   - sherpa-onnx: Version \(version)\n"
                } else {
                    report += "   - sherpa-onnx: Not found (Optional for diarization)\n"
                }
            } catch {
                report += "   - sherpa-onnx: Failed to run check\n"
            }
        } else {
            report += "✘ Python 3: Not found\n"
        }
        
        self.diagnosticsReport = report
        self.isCheckingDiagnostics = false
    }

    func scanObsidianTags(vaultPath: String) -> [String] {
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
                    uniqueTags.insert(cleaned)
                }
            }

            if let regex = inlineRegex {
                let nsText = content as NSString
                let matches = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsText.length))
                for m in matches {
                    if m.numberOfRanges > 1 {
                        let t = nsText.substring(with: m.range(at: 1))
                        uniqueTags.insert(t)
                    }
                }
            }
        }
        return Array(uniqueTags).sorted()
    }
}

// MARK: - Reusable Cocoa Bridged Viewers

struct LogViewer: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .textColor
        textView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
            textView.scrollToEndOfDocument(nil)
        }
    }
}

struct RichTextViewer: NSViewRepresentable {
    let text: String
    let highlightedRange: NSRange?
    let getSpeakerColors: (String) -> (bg: NSColor, active: NSColor)
    let extractSpeaker: (String) -> String?
    let onTextClicked: (Int) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
        
        let storage = textView.textStorage
        let len = storage?.length ?? 0
        guard len > 0 else { return }
        
        storage?.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: len))
        
        let lines = text.components(separatedBy: .newlines)
        var currentOffset = 0
        for line in lines {
            let lineLength = (line as NSString).length
            let lineRange = NSRange(location: currentOffset, length: lineLength)
            
            if let speaker = extractSpeaker(line) {
                let colors = getSpeakerColors(speaker)
                if let hr = highlightedRange, lineRange.location == hr.location && lineRange.length == hr.length {
                    storage?.addAttribute(.backgroundColor, value: colors.active, range: lineRange)
                } else {
                    storage?.addAttribute(.backgroundColor, value: colors.bg, range: lineRange)
                }
            } else if let hr = highlightedRange, lineRange.location == hr.location && lineRange.length == hr.length {
                storage?.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), range: lineRange)
            }
            currentOffset += lineLength + 1
        }
        
        if let hr = highlightedRange {
            textView.scrollRangeToVisible(hr)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextViewer
        init(_ parent: RichTextViewer) {
            self.parent = parent
        }
        
        func textViewDidChangeSelection(_ notification: Notification) {
            let textView = notification.object as! NSTextView
            let selectedRange = textView.selectedRange()
            if selectedRange.length == 0 {
                parent.onTextClicked(selectedRange.location)
            }
        }
    }
}

struct ContactsComboBox: NSViewRepresentable {
    @Binding var text: String
    let items: [String]

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.completes = true
        box.delegate = context.coordinator
        return box
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {
        nsView.removeAllItems()
        nsView.addItems(withObjectValues: items)
        nsView.stringValue = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ContactsComboBox
        init(_ parent: ContactsComboBox) {
            self.parent = parent
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            let box = notification.object as! NSComboBox
            parent.text = box.stringValue
        }

        func controlTextDidChange(_ obj: Notification) {
            let box = obj.object as! NSComboBox
            parent.text = box.stringValue
        }
    }
}

// MARK: - Modals and Sheets

struct RegisterVoiceSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    
    @State private var speakerLabel: String = ""
    @State private var audioSamplePath: String = ""
    @State private var statusMessage: String = ""
    @State private var isRunning: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Register Voice Profile")
                .font(.headline)
            
            Form {
                Section {
                    HStack {
                        Text("Contact or Label:")
                            .frame(width: 110, alignment: .leading)
                        ContactsComboBox(text: $speakerLabel, items: model.contacts)
                            .frame(maxWidth: .infinity)
                    }
                    HStack {
                        Text("Audio Sample:")
                            .frame(width: 110, alignment: .leading)
                        TextField("/path/to/sample.wav", text: $audioSamplePath)
                        Button("Browse…") {
                            let panel = NSOpenPanel()
                            panel.title = "Select audio sample"
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowedContentTypes = [.audio].compactMap { $0 }
                            if panel.runModal() == .OK, let url = panel.url {
                                audioSamplePath = url.path
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(statusMessage.hasPrefix("Success") ? .green : .secondary)
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isRunning)
                
                Button("Extract & Register") {
                    isRunning = true
                    statusMessage = "Analyzing audio signature..."
                    model.registerVoice(label: speakerLabel, filePath: audioSamplePath) { success, msg in
                        isRunning = false
                        statusMessage = msg
                        if success {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                dismiss()
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(speakerLabel.isEmpty || audioSamplePath.isEmpty || isRunning)
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(width: 450, height: 210)
        .onAppear {
            model.requestContactsPermissionAndReload()
        }
    }
}

struct RenameSpeakerSheet: View {
    @ObservedObject var model: AppModel
    let fileURL: URL
    @Environment(\.dismiss) var dismiss
    
    @State private var oldName: String = ""
    @State private var newName: String = ""
    @State private var detectedSpeakers: [String] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Speaker in Transcript")
                .font(.headline)
            
            if detectedSpeakers.isEmpty {
                Text("No speakers found to rename in this transcript.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                Form {
                    Picker("Speaker to Rename:", selection: $oldName) {
                        ForEach(detectedSpeakers, id: \.self) {
                            Text($0)
                        }
                    }
                    HStack {
                        Text("Rename to:")
                            .frame(width: 120, alignment: .leading)
                        ContactsComboBox(text: $newName, items: model.contacts)
                    }
                }
                .formStyle(.grouped)
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                if !detectedSpeakers.isEmpty {
                    Button("Rename") {
                        if let error = model.renameSpeaker(oldName: oldName, newName: newName, fileURL: fileURL) {
                            model.showSystemAlert(title: "Rename Failed", message: error)
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.isEmpty)
                }
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(width: 420, height: 180)
        .onAppear {
            model.requestContactsPermissionAndReload()
            // Parse speakers
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                var speakers = Set<String>()
                let lines = content.components(separatedBy: .newlines)
                for line in lines {
                    if let spk = model.extractSpeaker(from: line) {
                        speakers.insert(spk)
                    }
                }
                detectedSpeakers = Array(speakers).sorted()
                if let first = detectedSpeakers.first {
                    oldName = first
                }
            }
        }
    }
}

// MARK: - Tab Views

struct TranscribeView: View {
    @ObservedObject var model: AppModel
    @State private var isDragging: Bool = false
    @State private var showRegisterVoice: Bool = false
    @State private var showTagPopover: Bool = false
    
    var body: some View {
        VStack(spacing: 12) {
            // Drop zone area
            VStack {
                Text("Drag & Drop Audio/Video File Here")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 85)
            .background(isDragging ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDragging ? Color.accentColor : Color.gray.opacity(0.25), style: StrokeStyle(lineWidth: isDragging ? 2 : 1, dash: [4]))
            )
            .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let u = url {
                        DispatchQueue.main.async {
                            model.handleDroppedFile(u)
                        }
                    }
                }
                return true
            }
            
            // Grid Form Rows
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Audio File:")
                        .gridColumnAlignment(.trailing)
                        .font(.body)
                    HStack {
                        TextField("Select or drop audio/video file", text: $model.audioPath)
                        Button("Choose…") {
                            model.pickAudio()
                        }
                        Button("Voice Memos") {
                            model.pickVoiceMemos()
                        }
                    }
                }
                
                GridRow {
                    Text("Model File:")
                        .font(.body)
                    HStack {
                        TextField("Select Whisper model file", text: $model.modelPath)
                        Button("Choose…") {
                            model.pickModel()
                        }
                    }
                }
                
                GridRow {
                    Text("Custom Name:")
                        .font(.body)
                    TextField("Output filename (optional)", text: $model.customName)
                }

                GridRow {
                    Text("Note Name:")
                        .font(.body)
                    TextField("Obsidian/Header custom name (optional)", text: $model.noteName)
                }

                GridRow {
                    Text("Tags:")
                        .font(.body)
                    HStack {
                        TextField("meeting, podcast, work", text: $model.tags)
                        Button("Tag Selector") {
                            showTagPopover.toggle()
                        }
                        .popover(isPresented: $showTagPopover) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Select Tags:")
                                    .font(.headline)
                                    .padding(.bottom, 4)
                                
                                FlowLayout(spacing: 6) {
                                    ForEach(model.availableTags, id: \.self) { tag in
                                        Button(action: {
                                            var tagList = model.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                                            if tagList.contains(tag) {
                                                tagList.removeAll(where: { $0 == tag })
                                            } else {
                                                tagList.append(tag)
                                            }
                                            model.tags = tagList.joined(separator: ", ")
                                        }) {
                                            Text(tag)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(model.tags.contains(tag) ? Color.accentColor : Color.gray.opacity(0.2))
                                                .foregroundColor(model.tags.contains(tag) ? .white : .primary)
                                                .cornerRadius(12)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                
                                Divider().padding(.vertical, 4)
                                
                                Button("Import from Obsidian") {
                                    let vault = model.settings.obsidianVaultPath
                                    if !vault.isEmpty {
                                        let scanned = model.scanObsidianTags(vaultPath: vault)
                                        for t in scanned {
                                            if !model.availableTags.contains(t) {
                                                model.availableTags.append(t)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding()
                            .frame(width: 250)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            
            // Diarization toggle & speakers
            HStack(spacing: 16) {
                Toggle("Diarization (Speaker Profiling)", isOn: $model.settings.diarizeEnabled)
                    .toggleStyle(.checkbox)
                
                Text(model.registeredSpeakers)
                    .foregroundColor(.secondary)
                    .font(.callout)
                    .lineLimit(1)
                
                Spacer()
                
                Button("Register Voice…") {
                    showRegisterVoice = true
                }
                .sheet(isPresented: $showRegisterVoice) {
                    RegisterVoiceSheet(model: model)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)

            // Audio Player Bar
            if !model.audioPath.isEmpty && model.previewPlaybackDuration > 0 {
                HStack(spacing: 8) {
                    Button(action: {
                        model.playPausePreview()
                    }) {
                        Image(systemName: model.previewIsPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.plain)
                    
                    Slider(value: Binding(get: {
                        model.previewPlaybackTime
                    }, set: {
                        model.seekPreview(time: $0)
                    }), in: 0...model.previewPlaybackDuration)
                    
                    Text("\(formatTime(model.previewPlaybackTime)) / \(formatTime(model.previewPlaybackDuration))")
                        .font(.monospacedDigit(.caption)())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.12))
                .cornerRadius(6)
            }

            // Run action row
            HStack {
                if model.isTranscribing {
                    ProgressView(value: model.progressValue, total: 100)
                        .frame(width: 200)
                    Text(model.progressPercent)
                        .font(.body)
                    Text("(\(model.statusText))")
                        .foregroundColor(.secondary)
                        .font(.body)
                    Spacer()
                    Button("Cancel") {
                        model.stopProcess()
                    }
                } else {
                    Text(model.statusText)
                        .foregroundColor(.secondary)
                        .font(.body)
                    Spacer()
                    Button("Transcribe") {
                        model.runTranscribe()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 4)
            
            // Console & Transcription Preview
            VSplitView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Logs & Output")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    LogViewer(text: model.consoleLogs)
                        .frame(minHeight: 100)
                        .border(Color.gray.opacity(0.2))
                }
                .padding(.bottom, 6)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live Transcription Preview")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ScrollView {
                        Text(model.transcriptText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Color.black.opacity(0.1))
                    .border(Color.gray.opacity(0.2))
                }
            }
        }
        .padding()
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

struct BrowserView: View {
    @ObservedObject var model: AppModel
    @State private var filterQuery: String = ""
    @State private var showRenameSheet: Bool = false
    
    var filteredFiles: [URL] {
        if filterQuery.isEmpty {
            return model.browserFiles
        } else {
            return model.browserFiles.filter {
                $0.lastPathComponent.lowercased().contains(filterQuery.lowercased())
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Button("Choose Folder…") {
                        model.chooseBrowserDirectory()
                    }
                    Button("Refresh") {
                        model.loadBrowserDirectory()
                    }
                }
                
                if let path = model.selectedBrowserDir {
                    Text(path.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                TextField("Filter...", text: $filterQuery)
                    .textFieldStyle(.roundedBorder)
                
                List(filteredFiles, id: \.self) { file in
                    Button(action: {
                        model.selectBrowserFile(url: file)
                    }) {
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(.accentColor)
                            Text(file.lastPathComponent)
                                .lineLimit(1)
                                .font(.body)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .background(model.selectedBrowserURL == file ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                }
            }
            .frame(width: 250)
            .padding()
            
            Divider()
            
            if let selectedURL = model.selectedBrowserURL {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Text(selectedURL.lastPathComponent)
                            .font(.headline)
                        
                        Spacer()
                        
                        Button("Copy") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(model.browserTextContent, forType: .string)
                        }
                        
                        ShareLink(item: selectedURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        
                        Button("Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([selectedURL])
                        }
                        
                        Button("Rename Speaker…") {
                            showRenameSheet = true
                        }
                        .sheet(isPresented: $showRenameSheet) {
                            RenameSpeakerSheet(model: model, fileURL: selectedURL)
                        }
                        
                        Button("Delete") {
                            let alert = NSAlert()
                            alert.messageText = "Delete Transcript"
                            alert.informativeText = "Are you sure you want to delete \(selectedURL.lastPathComponent)?"
                            alert.addButton(withTitle: "Delete")
                            alert.addButton(withTitle: "Cancel")
                            if alert.runModal() == .alertFirstButtonReturn {
                                try? FileManager.default.removeItem(at: selectedURL)
                                model.selectedBrowserURL = nil
                                model.browserTextContent = ""
                                model.stopBrowserPlayer()
                                model.loadBrowserDirectory()
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top)

                    if model.browserAudioURL != nil {
                        HStack(spacing: 8) {
                            Button(action: {
                                model.playPauseBrowser()
                            }) {
                                Image(systemName: model.browserIsPlaying ? "pause.fill" : "play.fill")
                            }
                            .buttonStyle(.plain)
                            
                            Slider(value: Binding(get: {
                                model.browserPlaybackTime
                            }, set: {
                                model.seekBrowser(time: $0)
                            }), in: 0...model.browserPlaybackDuration)
                            
                            Text("\(formatTime(model.browserPlaybackTime)) / \(formatTime(model.browserPlaybackDuration))")
                                .font(.monospacedDigit(.caption)())
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.12))
                        .cornerRadius(6)
                        .padding(.horizontal)
                    }

                    RichTextViewer(
                        text: model.browserTextContent,
                        highlightedRange: model.highlightedRange,
                        getSpeakerColors: { model.getSpeakerColors(for: $0) },
                        extractSpeaker: { model.extractSpeaker(from: $0) },
                        onTextClicked: { offset in
                            if let matched = model.timestampRanges.first(where: { offset >= $0.range.location && offset <= ($0.range.location + $0.range.length) }) {
                                model.seekBrowser(time: matched.start)
                            }
                        }
                    )
                    .border(Color.gray.opacity(0.2))
                    .padding([.horizontal, .bottom])
                }
            } else {
                VStack {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a transcription from the list to view and play.")
                        .foregroundColor(.secondary)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

struct AdvancedView: View {
    @ObservedObject var model: AppModel
    
    var body: some View {
        ScrollView {
            Form {
                Section("Conversion Settings (ffmpeg)") {
                    TextField("ffmpeg path:", text: $model.settings.ffmpegPath)
                    
                    HStack {
                        Text("Sample Rate:")
                        TextField("Rate", value: $model.settings.sampleRate, format: .number)
                        Spacer()
                        Text("Channels:")
                        Picker("", selection: $model.settings.audioChannels) {
                            Text("1 (Mono)").tag(1)
                            Text("2 (Stereo)").tag(2)
                        }
                        .pickerStyle(.menu)
                    }
                    
                    Toggle("Strip Video (no video map)", isOn: $model.settings.stripVideo)
                        .toggleStyle(.checkbox)
                    
                    Picker("ffmpeg logs:", selection: $model.settings.ffmpegLogLevel) {
                        Text("warning").tag("warning")
                        Text("error").tag("error")
                        Text("info").tag("info")
                    }
                    .pickerStyle(.menu)
                    
                    Toggle("Force Conversion (re-run ffmpeg always)", isOn: $model.settings.forceConvert)
                        .toggleStyle(.checkbox)
                }

                Section("Transcription Settings (whisper-cli)") {
                    TextField("whisper-cli path:", text: $model.settings.cliPath)
                    
                    HStack {
                        Text("Threads:")
                        TextField("", value: $model.settings.threads, format: .number)
                        Spacer()
                        Text("Language:")
                        Picker("", selection: $model.settings.language) {
                            Text("auto").tag("auto")
                            Text("en").tag("en")
                            Text("fr").tag("fr")
                            Text("de").tag("de")
                            Text("es").tag("es")
                            Text("it").tag("it")
                        }
                        .pickerStyle(.menu)
                    }
                    
                    HStack {
                        Toggle("GPU Acceleration", isOn: $model.settings.useGpu)
                            .toggleStyle(.checkbox)
                        Toggle("Translate to English", isOn: $model.settings.translate)
                            .toggleStyle(.checkbox)
                        Toggle("No Timestamps", isOn: $model.settings.noTimestamps)
                            .toggleStyle(.checkbox)
                    }
                    
                    TextField("Initial prompt:", text: $model.settings.initialPrompt)
                }

                Section("Obsidian Integration") {
                    TextField("Obsidian Vault Path:", text: $model.settings.obsidianVaultPath)
                    Button("Browse Vault Folder…") {
                        model.pickObsidianVault()
                    }
                    
                    Toggle("Auto-Save directly to Vault folder", isOn: $model.settings.obsidianSaveDirectly)
                        .toggleStyle(.checkbox)
                    
                    TextField("Notes Subfolder:", text: $model.settings.obsidianFolder)
                }

                Section("Diarization Advanced Settings") {
                    HStack {
                        Text("Clustering Threshold (0.1 - 1.0):")
                        TextField("", value: $model.settings.diarizeThreshold, format: .number)
                        Spacer()
                        Text("Max Speakers (0 = auto):")
                        TextField("", value: $model.settings.diarizeSpeakers, format: .number)
                    }
                }

                Section("System Diagnostics") {
                    HStack {
                        Button("Check Dependencies") {
                            model.checkDependencies()
                        }
                        Button("Check Whisper Updates") {
                            model.checkWhisperUpdate()
                        }
                        Button("Check Sherpa Updates") {
                            model.checkSherpaUpdate()
                        }
                    }
                    
                    if !model.dependencyCheckStatus.isEmpty {
                        Text(model.dependencyCheckStatus)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    
                    if !model.diagnosticsReport.isEmpty {
                        Text(model.diagnosticsReport)
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .background(Color.black.opacity(0.12))
                            .border(Color.gray.opacity(0.3))
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
    }
}

// MARK: - Layout Utilities

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width {
                currentX = 0
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            currentX += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
        height = currentY + maxHeightInRow
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
    }
}

// MARK: - Root Window ContentView

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab: Tab = .transcribe

    enum Tab {
        case transcribe
        case browser
        case advanced
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: Tab.transcribe) {
                    Label("Transcribe", systemImage: "waveform.circle.fill")
                }
                NavigationLink(value: Tab.browser) {
                    Label("Browser", systemImage: "folder.fill")
                }
                NavigationLink(value: Tab.advanced) {
                    Label("Advanced Settings", systemImage: "gearshape.fill")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Whisper GUI")
        } detail: {
            switch selectedTab {
            case .transcribe:
                TranscribeView(model: model)
            case .browser:
                BrowserView(model: model)
            case .advanced:
                AdvancedView(model: model)
            }
        }
        .frame(minWidth: 950, minHeight: 650)
        .alert(model.alertTitle, isPresented: $model.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage)
        }
    }
}

// MARK: - SwiftUI Main Entry Point

@main
struct WhisperGUIApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    model.loadContacts()
                    model.refreshSpeakersList()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}
