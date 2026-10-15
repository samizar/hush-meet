import SwiftUI
import HushKit

struct LiveLine: View {
    var capture: CaptureSession
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion") }
    var body: some View {
        VStack(spacing: DesignTokens.space) {
            if reduceMotion {
                HStack {
                    Circle().fill(DesignTokens.ink.opacity((capture.meLevels.last ?? 0) > 0.02 ? 1 : 0.2))
                    Spacer()
                    Circle().fill(DesignTokens.soft.opacity((capture.themLevels.last ?? 0) > 0.02 ? 1 : 0.2))
                }.frame(height: DesignTokens.dot)
            } else {
                Canvas { context, size in
                    for (levels, position, color) in [(capture.meLevels, 0.3, DesignTokens.ink), (capture.themLevels, 0.75, DesignTokens.soft)] {
                        var path = Path()
                        for (index, level) in levels.enumerated() {
                            let x = size.width * Double(index) / Double(max(1, levels.count - 1))
                            let direction = index.isMultiple(of: 2) ? 1.0 : -1.0
                            let y = size.height * position + direction * level * size.height * 0.24
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: DesignTokens.lineWidth, lineCap: .round, lineJoin: .round))
                    }
                }.frame(height: DesignTokens.liveHeight)
            }
            HStack { Text("Me"); Spacer(); Text("Them") }.font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Voice levels. Microphone and system audio.")
    }
}

struct LiveTranscript: View {
    var capture: CaptureSession
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space) {
            if let segment = capture.transcript?.segments.last {
                Text(segment.speaker.label + ": " + segment.text).font(DesignTokens.body).foregroundStyle(DesignTokens.soft)
            }
            if !capture.volatileMe.isEmpty { Text("Me: " + capture.volatileMe).foregroundStyle(DesignTokens.soft.opacity(0.4)) }
            if !capture.volatileThem.isEmpty { Text("Them: " + capture.volatileThem).foregroundStyle(DesignTokens.soft.opacity(0.4)) }
        }.font(DesignTokens.body).lineSpacing(DesignTokens.noteLineSpacing).frame(maxWidth: .infinity, alignment: .leading)
    }
}
