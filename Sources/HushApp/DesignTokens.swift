import SwiftUI
import AppKit

/// Every colour, size, radius and motion value Hush uses. Views never hard-code these.
enum DesignTokens {
    // MARK: Colour — warm paper and ink, one recording accent.
    static let paper = adaptive(light: 0xF7F5F0, dark: 0x161614)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1E1E1B)
    static let well = adaptive(light: 0xEFECE5, dark: 0x232320)
    static let sidebar = adaptive(light: 0xF0EEE8, dark: 0x1B1B18)
    static let ink = adaptive(light: 0x1A1916, dark: 0xECE9E2)
    static let soft = ink.opacity(0.6)
    static let faint = ink.opacity(0.38)
    static let hairline = ink.opacity(0.09)
    static let selected = ink.opacity(0.07)
    static let hover = ink.opacity(0.045)
    static let ember = adaptive(light: 0xD9502F, dark: 0xE8673F)
    static let emberWash = ember.opacity(0.1)
    /// The other side of the call, in transcripts and level meters.
    static let them = adaptive(light: 0x4D6B7A, dark: 0x93B4C4)
    static let sage = adaptive(light: 0x4C7A5A, dark: 0x86BD96)
    static let amber = adaptive(light: 0x9A6312, dark: 0xE2A64E)

    // MARK: Type — SF Pro throughout, monospaced digits for time.
    static let display = Font.system(size: 30, weight: .semibold)
    static let title = Font.system(size: 26, weight: .semibold)
    static let heading = Font.system(size: 17, weight: .semibold)
    static let section = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 15)
    static let chrome = Font.system(size: 13)
    static let chromeStrong = Font.system(size: 13, weight: .medium)
    static let small = Font.system(size: 11.5)
    static let label = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12).monospacedDigit()
    static let timer = Font.system(size: 34, weight: .light).monospacedDigit()

    // MARK: Spacing
    static let hairlineWidth: CGFloat = 1
    static let smallGap: CGFloat = 4
    static let space: CGFloat = 8
    static let gap: CGFloat = 12
    static let inset: CGFloat = 16
    static let block: CGFloat = 24
    static let margin: CGFloat = 40
    static let pageMargin: CGFloat = 56
    static let rowInset: CGFloat = 10
    static let indent: CGFloat = 22

    // MARK: Shape
    static let radius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let lineWidth: CGFloat = 1.5
    static let divider: CGFloat = 1
    static let dot: CGFloat = 8
    static let icon: CGFloat = 14
    static let noteLineSpacing: CGFloat = 6
    static let dryingOffset: CGFloat = 4

    // MARK: Layout
    static let pageWidth: CGFloat = 700
    static let sidebarWidth: CGFloat = 270
    static let inspectorWidth: CGFloat = 290
    static let detailMinWidth: CGFloat = 380
    static let popoverWidth: CGFloat = 340
    static let windowWidth: CGFloat = 1240
    static let windowHeight: CGFloat = 800
    static let minWindowWidth: CGFloat = 860
    static let minWindowHeight: CGFloat = 520
    static let settingsWidth: CGFloat = 780
    static let settingsHeight: CGFloat = 580
    static let onboardingWidth: CGFloat = 540
    static let onboardingHeight: CGFloat = 560
    static let liveHeight: CGFloat = 56
    static let buttonHeight: CGFloat = 32
    static let largeButtonHeight: CGFloat = 40

    // MARK: Motion
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let fade = Animation.easeOut(duration: 0.22)
    static let quick = Animation.easeOut(duration: 0.15)
    static let stagger = 0.025
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

extension EnvironmentValues {
    /// Reduce Motion from the system or the `--reduce-motion` preview flag.
    var hushReduceMotion: Bool { accessibilityReduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion") }
}
