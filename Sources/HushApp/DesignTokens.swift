import SwiftUI
import AppKit

enum DesignTokens {
    static let paper = adaptive(light: 0xF7F5F0, dark: 0x151513)
    static let ink = adaptive(light: 0x1A1916, dark: 0xECE9E2)
    static let soft = ink.opacity(0.55)
    static let faint = ink.opacity(0.32)
    static let hairline = adaptive(light: 0x1A1916, dark: 0xECE9E2).opacity(0.09)
    static let sidebar = adaptive(light: 0xF0EEE8, dark: 0x1B1B18)
    static let selected = ink.opacity(0.065)
    static let ember = adaptive(light: 0xD9502F, dark: 0xE8673F)
    static let body = Font.system(size: 15, weight: .regular)
    static let title = Font.system(size: 22, weight: .medium)
    static let display = Font.system(size: 32, weight: .regular)
    static let section = Font.system(size: 15, weight: .medium)
    static let chrome = Font.system(size: 13)
    static let small = Font.system(size: 11)
    static let mono = Font.system(size: 11).monospacedDigit()
    static let space: CGFloat = 8
    static let smallGap: CGFloat = 4
    static let gap: CGFloat = 12
    static let inset: CGFloat = 20
    static let margin: CGFloat = 40
    static let pageMargin: CGFloat = 56
    static let rowInset: CGFloat = 14
    static let radius: CGFloat = 6
    static let lineWidth: CGFloat = 1.5
    static let divider: CGFloat = 1
    static let pageWidth: CGFloat = 640
    static let sidebarWidth: CGFloat = 260
    static let sideNotesWidth: CGFloat = 280
    static let popoverWidth: CGFloat = 320
    static let windowWidth: CGFloat = 1180
    static let windowHeight: CGFloat = 740
    static let minWindowWidth: CGFloat = 800
    static let minWindowHeight: CGFloat = 520
    static let settingsWidth: CGFloat = 580
    static let settingsHeight: CGFloat = 530
    static let onboardingWidth: CGFloat = 450
    static let onboardingHeight: CGFloat = 450
    static let liveHeight: CGFloat = 56
    static let buttonHeight: CGFloat = 34
    static let icon: CGFloat = 14
    static let dot: CGFloat = 7
    static let indent: CGFloat = 24
    static let noteLineSpacing: CGFloat = 7.5
    static let dryingOffset: CGFloat = 4
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let fade = Animation.easeOut(duration: 0.22)
    static let stagger = 0.03
    static let breathDuration = 2.4
    static let breathScale: CGFloat = 0.85
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion")
    }
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func hushEnvironment() -> some View {
        self.tint(DesignTokens.ink)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    var recording = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(DesignTokens.chrome)
            .padding(.horizontal, DesignTokens.gap).frame(minHeight: DesignTokens.buttonHeight)
            .foregroundStyle(prominent ? DesignTokens.paper : DesignTokens.ink)
            .background((recording ? DesignTokens.ember : prominent ? DesignTokens.ink : DesignTokens.selected)
                .opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: DesignTokens.radius))
            .contentShape(Rectangle())
    }
}
