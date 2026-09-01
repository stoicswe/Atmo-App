import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AtmoCore

// MARK: - Voice Memo Sheet
/// Record a clip (or pick an audio file), preview it, and attach it as a
/// waveform video — Bluesky hosts video, so voice memos travel as one.
/// Attaching hands over an audio *reference*; the waveform video renders
/// at publish time (PostPublisher), so this sheet closes instantly.
struct VoiceMemoSheet: View {
    /// Called with the audio take's file URL and its duration.
    let onAttach: (URL, TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var recorder: AVAudioRecorder? = nil
    @State private var isRecording = false
    @State private var elapsed: TimeInterval = 0
    @State private var takeURL: URL? = nil
    @State private var player: AVAudioPlayer? = nil
    @State private var isPlaying = false
    @State private var showImporter = false
    @State private var isRendering = false
    @State private var errorText: String? = nil
    @State private var tickTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: AtmoTheme.Spacing.xl) {
                Spacer(minLength: 0)

                Text(timeString(elapsed))
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isRecording ? .primary : .secondary)

                // Record / stop
                Button {
                    Haptics.tap()
                    Task { await toggleRecording() }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 4)
                            .frame(width: 88, height: 88)
                        RoundedRectangle(cornerRadius: isRecording ? 8 : 36, style: .continuous)
                            .fill(Color.red)
                            .frame(width: isRecording ? 34 : 72, height: isRecording ? 34 : 72)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRendering)
                .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")

                Text(isRecording
                     ? "Recording… up to 3 minutes"
                     : takeURL == nil ? "Tap to record a voice memo" : "Take ready")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if takeURL != nil, !isRecording {
                    Button {
                        Haptics.tap()
                        togglePlayback()
                    } label: {
                        Label(isPlaying ? "Pause" : "Play back", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRendering)
                }

                Button {
                    showImporter = true
                } label: {
                    Label("Choose Audio File", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .disabled(isRecording || isRendering)

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)

                Button {
                    Task { await attach() }
                } label: {
                    if isRendering {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Attaching…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Attach Voice Memo", systemImage: "waveform")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AtmoColors.accent)
                .disabled(takeURL == nil || isRecording || isRendering)
            }
            .padding(AtmoTheme.Spacing.xl)
            .navigationTitle("Voice Memo")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stopEverything()
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
                importFile(result)
            }
            .onDisappear { stopEverything() }
        }
        .themedBackdrop()
#if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
#endif
    }

    // MARK: Recording

    private func toggleRecording() async {
        if isRecording {
            finishRecording()
            return
        }
        errorText = nil
#if os(iOS)
        guard await AVAudioApplication.requestRecordPermission() else {
            errorText = "Microphone access is off — enable it in Settings to record."
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
#endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmo-memo-\(UUID().uuidString).m4a")
        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ])
            guard newRecorder.record() else {
                errorText = "Couldn't start recording."
                return
            }
            stopPlayback()
            recorder = newRecorder
            takeURL = url
            isRecording = true
            elapsed = 0
            tickTask = Task { @MainActor in
                while !Task.isCancelled, isRecording {
                    try? await Task.sleep(for: .milliseconds(250))
                    elapsed = recorder?.currentTime ?? elapsed
                    // Hard stop at the video length cap.
                    if elapsed >= VideoConstraints.maxDuration {
                        finishRecording()
                    }
                }
            }
        } catch {
            errorText = "Couldn't start recording."
        }
    }

    private func finishRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        tickTask?.cancel()
        Haptics.confirm()
    }

    // MARK: Playback

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }
        guard let takeURL, let newPlayer = try? AVAudioPlayer(contentsOf: takeURL) else { return }
        player = newPlayer
        newPlayer.play()
        isPlaying = true
        Task { @MainActor in
            while isPlaying, player?.isPlaying == true {
                try? await Task.sleep(for: .milliseconds(200))
            }
            isPlaying = false
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func stopEverything() {
        if isRecording { finishRecording() }
        stopPlayback()
        tickTask?.cancel()
    }

    // MARK: Import

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmo-memo-import-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: local)
            stopPlayback()
            takeURL = local
            elapsed = 0
            errorText = nil
        } catch {
            errorText = "Couldn't read that audio file."
        }
    }

    // MARK: Attach

    private func attach() async {
        guard let takeURL else { return }
        stopPlayback()
        isRendering = true
        errorText = nil

        // Validate the take is a readable clip inside the length cap —
        // publish-time rendering can't fix either, and that feedback
        // belongs here, not in a failed background upload later.
        let asset = AVURLAsset(url: takeURL)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0.2 else {
            errorText = "Couldn't read that audio. Try re-recording."
            isRendering = false
            return
        }
        if let violation = VideoConstraints.validate(byteCount: 0, duration: duration) {
            errorText = violation.userMessage
            isRendering = false
            return
        }

        // Hand the composer its own copy, so this sheet's temp files can
        // never be cleaned out from under a queued publish.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmo-memo-ref-\(UUID().uuidString).\(takeURL.pathExtension)")
        do {
            try FileManager.default.copyItem(at: takeURL, to: kept)
            onAttach(kept, duration)
            Haptics.confirm()
            dismiss()
        } catch {
            errorText = "Couldn't attach that audio. Try re-recording."
        }
        isRendering = false
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
