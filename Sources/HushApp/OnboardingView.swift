import SwiftUI
import UserNotifications
import AVFoundation
import HushKit
import MuesliAudio

struct OnboardingView: View {
    @Bindable var state: AppState
    var finished: () -> Void
    @State private var step = 0
    @State private var granted = false
    @State private var testing = false
    @State private var level: Double = 0
    @State private var samples: [Double] = Array(repeating: 0, count: 60)
    @State private var message: String?
    @State private var testTask: Task<Void, Never>?
    @State private var testCapture: SystemAudioCapture?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion") }
    private var title: String { ["A little room to listen.", "Both sides of the conversation.", "A quiet tap before your meeting.", "You're set."][step] }
    private var subtitle: String {
        ["Hush uses your microphone for your side of a meeting. Your words stay on this Mac with the default settings.",
         "System audio captures the other side on a separate track. Play something, then run the ten-second test. Headphones help.",
         "Hush can read Apple Calendar and remind you one minute before a meeting. No separate sign-in.",
         "Hush will tap you before your next meeting. You can also start any time from the circle in your menu bar."][step]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.indent) {
            HStack { Text("hush").font(DesignTokens.title); Spacer(); if step < 3 { Text("\(step + 1) / 3").font(DesignTokens.mono).foregroundStyle(DesignTokens.soft) } }
            Spacer(minLength: DesignTokens.space)
            Text(title).font(DesignTokens.title)
            Text(subtitle).font(DesignTokens.body).foregroundStyle(DesignTokens.soft).lineSpacing(DesignTokens.noteLineSpacing)
            if step == 1 {
                Canvas { context, size in
                    if reduceMotion {
                        context.fill(Path(ellipseIn: CGRect(x: size.width / 2, y: size.height / 2, width: DesignTokens.dot, height: DesignTokens.dot)), with: .color(DesignTokens.ink.opacity(level > 0.01 ? 1 : 0.2)))
                    } else {
                        var line = Path()
                        for (index, value) in samples.enumerated() {
                            let point = CGPoint(x: size.width * Double(index) / Double(samples.count - 1), y: size.height / 2 + (index.isMultiple(of: 2) ? 1 : -1) * value * size.height * 0.4)
                            if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                        }
                        context.stroke(line, with: .color(DesignTokens.ink), lineWidth: DesignTokens.lineWidth)
                    }
                }.frame(height: DesignTokens.liveHeight).accessibilityLabel("System audio test level")
            }
            if let message { Text(message).font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft) }
            Spacer(minLength: DesignTokens.space)
            HStack(spacing: DesignTokens.gap) {
                if step == 3 {
                    Button("Open my notebook") { complete() }.buttonStyle(QuietButtonStyle(prominent: true))
                } else {
                    Button(testing ? "Listening for 10 seconds…" : granted ? "Continue" : ["Allow microphone", "Test system audio", "Allow calendar"][step]) {
                        if granted { advance() } else { request() }
                    }.buttonStyle(QuietButtonStyle(prominent: true)).disabled(testing)
                    Button("Skip for now") { advance() }.buttonStyle(.plain).foregroundStyle(DesignTokens.soft).disabled(testing)
                }
            }
        }.padding(DesignTokens.margin).frame(width: DesignTokens.onboardingWidth, height: DesignTokens.onboardingHeight)
            .background(DesignTokens.paper).foregroundStyle(DesignTokens.ink).tint(DesignTokens.ink)
            .onDisappear { testTask?.cancel(); testCapture?.stop() }
    }
    private func complete() { state.preferences.onboardingCompleted = true; finished() }
    private func advance() {
        testTask?.cancel(); testCapture?.stop(); testCapture = nil
        withAnimation(reduceMotion ? DesignTokens.fade : DesignTokens.spring) { step = min(3, step + 1); granted = false; message = nil }
    }
    private func request() {
        switch step {
        case 0:
            Task {
                granted = await MicrophoneCapture.requestAccess()
                message = granted ? "Microphone ready." : "Allow Hush in System Settings → Privacy & Security → Microphone, or skip for now."
            }
        case 1: testSystemAudio()
        case 2:
            Task { granted = await state.calendar.requestAccess(); state.preferences.calendarEnabled = granted
                if granted { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); state.scheduleNotifications() }
                message = granted ? "Calendar ready." : "You can connect Calendar later in Settings."
            }
        default: break
        }
    }
    private func testSystemAudio() {
        testing = true; message = nil
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
                            level = min(1, Double(peak) * 3); samples.removeFirst(); samples.append(level)
                        }
                    }
                }
                try await Task.sleep(for: .seconds(10)); capture.stop(); await reader.value
                granted = samples.contains { $0 > 0.005 }
                message = granted ? "Both sides are ready." : "Couldn't hear system audio. Play a sound and try again, or allow Hush in System Settings → Privacy & Security → Screen & System Audio Recording."
            } catch { capture.stop(); message = error.localizedDescription }
            testing = false; testCapture = nil
        }
    }
}
