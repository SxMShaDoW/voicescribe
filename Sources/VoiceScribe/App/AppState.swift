import AppKit
import Combine
import Foundation
import VoiceScribeCore

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var state: RecordingState = .idle
    @Published var lastTranscription: String = ""
    @Published var audioLevel: Float = 0
    @Published var showOnboarding = false
    @Published var hasShownSettingsOnLaunch = false
    @Published var triggerKey: TriggerKey = .saved {
        didSet {
            triggerKey.save()
            restartMonitoring()
        }
    }

    let permissionManager = PermissionManager()
    let transcriptionEngine = TranscriptionEngine()

    private var fnKeyMonitor: FnKeyMonitor?
    private var spacebarMonitor: SpacebarMonitor?
    private let audioRecorder = AudioRecorder()
    private let textInserter = TextInserter()

    private var audioLevelTimer: Timer?

    init() {
        setupMonitor()
    }

    func initialize() async {
        permissionManager.checkAllPermissions()

        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if !hasCompletedOnboarding {
            showOnboarding = true
            return
        }

        if transcriptionEngine.isModelDownloaded(transcriptionEngine.selectedModel) {
            await loadModel()
        }

        startMonitoring()
    }

    func loadModel() async {
        guard transcriptionEngine.isModelDownloaded(transcriptionEngine.selectedModel) else {
            return
        }

        do {
            try await transcriptionEngine.loadModel()
            state = .idle
        } catch {
            state = .error("Failed to load: \(error.localizedDescription)")
        }
    }

    var needsModelDownload: Bool {
        !transcriptionEngine.modelInfos.contains { $0.isDownloaded }
    }

    func startMonitoring() {
        switch triggerKey {
        case .fn:
            guard let monitor = fnKeyMonitor else { return }
            let success = monitor.start()
            if !success {
                state = .error("Failed to start Fn key monitoring. Check Input Monitoring permission.")
            }
        case .spacebar:
            guard let monitor = spacebarMonitor else { return }
            let success = monitor.start()
            if !success {
                state = .error("Failed to start spacebar monitoring. Check Accessibility permission.")
            }
        }
    }

    func stopMonitoring() {
        fnKeyMonitor?.stop()
        spacebarMonitor?.stop()
    }

    private func restartMonitoring() {
        stopMonitoring()
        setupMonitor()
        // Only start if we're past onboarding and model is loaded
        if !showOnboarding && transcriptionEngine.isModelLoaded {
            startMonitoring()
        }
    }

    private func setupMonitor() {
        let callback: (Bool) -> Void = { [weak self] pressed in
            Task { @MainActor [weak self] in
                self?.handleKeyStateChange(pressed: pressed)
            }
        }

        switch triggerKey {
        case .fn:
            spacebarMonitor = nil
            fnKeyMonitor = FnKeyMonitor(onFnKeyStateChanged: callback)
        case .spacebar:
            fnKeyMonitor = nil
            spacebarMonitor = SpacebarMonitor(onKeyStateChanged: callback)
        }
    }

    private func handleKeyStateChange(pressed: Bool) {
        if pressed {
            startRecording()
        } else if case .recording = state {
            stopRecordingAndTranscribe()
        }
    }

    private func startRecording() {
        guard state.isIdle else { return }
        guard transcriptionEngine.isModelLoaded else {
            state = .error("Model not loaded")
            return
        }

        do {
            try audioRecorder.startRecording()
            state = .recording
            startAudioLevelMonitoring()
            playStartSound()
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard case .recording = state else { return }

        stopAudioLevelMonitoring()
        let samples = audioRecorder.stopRecording()
        state = .processing

        Task {
            await transcribe(samples: samples)
        }
    }

    private func transcribe(samples: [Float]) async {
        do {
            let text = try await transcriptionEngine.transcribe(audioSamples: samples)

            if !text.isEmpty {
                lastTranscription = text
                textInserter.insertText(text)
                playSuccessSound()
            }

            state = .idle
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.state = .idle
            }
        }
    }

    private func startAudioLevelMonitoring() {
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.audioLevel = self?.audioRecorder.audioLevel ?? 0
            }
        }
    }

    private func stopAudioLevelMonitoring() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
        audioLevel = 0
    }

    private func playStartSound() {
        NSSound(named: "Tink")?.play()
    }

    private func playSuccessSound() {
        NSSound(named: "Pop")?.play()
    }
}
