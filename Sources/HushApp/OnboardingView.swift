import SwiftUI
import UserNotifications
import AVFoundation
import EventKit
import HushKit
import MuesliAudio

struct OnboardingView: View {
    @Bindable var state: AppState
    var finished: (_ startRecording: Bool) -> Void
    @State private var step = 0
    @State private var granted: [Int: Bool] = [:]
    @State private var testing = false
    @State private var samples: [Double] = Array(repeating: 0, count: 80)
    @State private var message: String?
    @State private var testTask: Task<Void, Never>?
    @State private var testCapture: SystemAudioCapture?
    @Environment(\.hushReduceMotion) private var reduceMotion
    private let count = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule().fill(index <= step ? DesignTokens.ink : DesignTokens.hairline).frame(width: index == step ? 22 : 8, height: 6)
                }
            }
            .animation(DesignTokens.spring, value: step)
            .padding(.top, DesignTokens.margin)
            Spacer(minLength: DesignTokens.inset)
            VStack(spacing: DesignTokens.inset) {
                icon
                Text(title).font(DesignTokens.title).multilineTextAlignment(.center)
                Text(subtitle).font(DesignTokens.body).foregroundStyle(DesignTokens.soft).multilineTextAlignment(.center)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 400)
                if step == 2 { meter }
                if step == 4 { tips }
                if let message {
                    Label(message, systemImage: granted[step] == true ? "checkmark.circle.fill" : "info.circle")
                        .font(DesignTokens.chrome).foregroundStyle(granted[step] == true ? DesignTokens.sage : DesignTokens.soft)
                        .multilineTextAlignment(.center).frame(maxWidth: 400)
                }
            }
            .padding(.horizontal, DesignTokens.margin)
            .id(step)
            .transition(.opacity.combined(with: .move(edge: reduceMotion ? .top : .trailing)).animation(DesignTokens.fade))
            Spacer(minLength: DesignTokens.inset)
            footer.padding(DesignTokens.block)
        }
        .frame(width: DesignTokens.onboardingWidth, height: DesignTokens.onboardingHeight)
        .background(DesignTokens.paper).foregroundStyle(DesignTokens.ink).tint(DesignTokens.ink)
        .onAppear(perform: refreshStatus)
        .onDisappear { testTask?.cancel(); testCapture?.stop() }
    }

    private var icon: some View {
        let symbol = ["waveform", "mic", "speaker.wave.2", "calendar", "checkmark"][step]
        return Image(systemName: symbol).font(.system(size: 26, weight: .regular))
            .foregroundStyle(step == 0 ? DesignTokens.ember : DesignTokens.ink)
            .frame(width: 64, height: 64)
            .background(step == 0 ? DesignTokens.emberWash : DesignTokens.selected, in: Circle())
    }
    private var title: String {
        ["Welcome to Hush", "Your side of the conversation", "The other side of the call", "A tap before each meeting", "You're set"][step]
    }
    private var subtitle: String {
        ["Hush records your meetings, transcribes them and writes clear notes on this Mac. No account, and your meetings never leave it unless you choose.",
         "Hush uses your microphone for what you say. It's only on while you're recording.",
         "System audio captures the call on its own track. Play something — a video, a song — then run the ten-second test. Headphones keep the two sides clean.",
         "Hush can read your calendar to remind you a minute before calls, with a one-click Join & record. Read-only, no separate sign-in.",
         "Press Record when a call starts. Notes appear a few moments after you stop."][step]
    }

    private var meter: some View {
        VStack(spacing: DesignTokens.space) {
            Canvas { context, size in
                var line = Path()
                for (index, value) in samples.enumerated() {
                    let point = CGPoint(x: size.width * Double(index) / Double(samples.count - 1),
                                        y: size.height / 2 + (index.isMultiple(of: 2) ? 1 : -1) * value * size.height * 0.42)
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                context.stroke(line, with: .color(DesignTokens.them), style: StrokeStyle(lineWidth: DesignTokens.lineWidth, lineCap: .round, lineJoin: .round))
            }
            .frame(height: DesignTokens.liveHeight).frame(maxWidth: 380)
            .accessibilityLabel("System audio test level")
        }
        .padding(.vertical, DesignTokens.space)
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            tip("menubar.rectangle", "Hush lives in the menu bar", "Click the circle to start, follow along or open your notebook.")
            tip("keyboard", "⌃⌥⌘R starts and stops recording", "From any app, whenever a call begins.")
            tip("headphones", "Wear headphones", "Your voice and theirs stay on separate, clearer tracks.")
        }
        .padding(DesignTokens.inset)
        .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.cardRadius).strokeBorder(DesignTokens.hairline))
        .frame(maxWidth: 420)
    }
    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.gap) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(DesignTokens.soft)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DesignTokens.chromeStrong)
                Text(detail).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.gap) {
            if step > 0 && step < 4 {
                Button("Back") { go(step - 1) }.buttonStyle(.hushQuiet).disabled(testing)
            }
            Spacer()
            switch step {
            case 0:
                Button("Get started") { go(1) }.buttonStyle(HushButtonStyle(kind: .primary, large: true)).keyboardShortcut(.defaultAction)
            case 4:
                Button("Open my notebook") { complete(false) }.buttonStyle(HushButtonStyle(kind: .secondary, large: true))
                Button("Record my first meeting") { complete(true) }.buttonStyle(HushButtonStyle(kind: .record, large: true)).keyboardShortcut(.defaultAction)
            default:
                Button("Skip for now") { go(step + 1) }.buttonStyle(.hushQuiet).disabled(testing)
                if granted[step] == true {
                    Button("Continue") { go(step + 1) }.buttonStyle(HushButtonStyle(kind: .primary, large: true)).keyboardShortcut(.defaultAction)
                } else {
                    Button(testing ? "Listening…" : ["", "Allow microphone", "Run the test", "Connect Calendar"][step]) { request() }
                        .buttonStyle(HushButtonStyle(kind: .primary, large: true)).disabled(testing).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func refreshStatus() {
        if MicrophoneCapture.isAuthorized { granted[1] = true }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { granted[3] = true }
    }
    private func go(_ next: Int) {
        testTask?.cancel(); testCapture?.stop(); testCapture = nil; testing = false
        withAnimation(reduceMotion ? DesignTokens.fade : DesignTokens.spring) {
            step = max(0, min(count - 1, next)); message = granted[step] == true ? alreadyGranted : nil
        }
    }
    private var alreadyGranted: String? {
        switch step { case 1: "Microphone is ready."; case 3: "Calendar is connected."; default: nil }
    }
    private func complete(_ record: Bool) { state.preferences.onboardingCompleted = true; finished(record) }
    private func request() {
        switch step {
        case 1:
            Task {
                let ok = await MicrophoneCapture.requestAccess(); granted[1] = ok
                message = ok ? "Microphone is ready." : "Allow Hush in System Settings → Privacy & Security → Microphone, or skip for now."
                if !ok { NSWorkspace.shared.open(CaptureSession.microphoneSettings) }
            }
        case 2: testSystemAudio()
        case 3:
            Task {
                let ok = await state.calendar.requestAccess(); granted[3] = ok; state.preferences.calendarEnabled = ok
                if ok { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); state.scheduleNotifications() }
                message = ok ? "Calendar is connected." : "You can connect Calendar any time in Settings → Recording."
            }
        default: break
        }
    }
    private func testSystemAudio() {
        testing = true; message = nil; samples = Array(repeating: 0, count: samples.count)
        let capture = SystemAudioCapture(); testCapture = capture
        testTask = Task {
            do {
                let stream = try capture.start()
                let reader = Task {
                    for await chunk in stream {
                        guard !Task.isCancelled else { break }
                        if let values = chunk.buffer.floatChannelData {
                            var peak: Float = 0
                            for i in stride(from: 0, to: Int(chunk.buffer.frameLength), by: 64) { peak = max(peak, abs(values[0][i])) }
                            samples.removeFirst(); samples.append(min(1, Double(peak) * 3))
                        }
                    }
                }
                try await Task.sleep(for: .seconds(10)); capture.stop(); await reader.value
                let heard = samples.contains { $0 > 0.005 }
                granted[2] = heard
                message = heard ? "Both sides are ready." : "Hush couldn't hear anything. Play a sound and try again, or allow Hush in Screen & System Audio Recording."
            } catch { capture.stop(); message = error.localizedDescription }
            testing = false; testCapture = nil
        }
    }
}
