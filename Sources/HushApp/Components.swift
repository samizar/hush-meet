import SwiftUI
import HushKit
import MuesliCore

// MARK: Buttons

struct HushButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, record, stop, quiet }
    var kind: Kind = .secondary
    var large = false
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? DesignTokens.chromeStrong.weight(.semibold) : DesignTokens.chromeStrong)
            .lineLimit(1)
            .padding(.horizontal, large ? DesignTokens.inset : DesignTokens.gap)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: large ? DesignTokens.largeButtonHeight : DesignTokens.buttonHeight)
            .foregroundStyle(foreground)
            .background(background.opacity(configuration.isPressed ? 0.78 : hovering && isEnabled ? 0.9 : 1),
                        in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .strokeBorder(kind == .secondary ? DesignTokens.hairline : .clear, lineWidth: DesignTokens.divider))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.radius))
            .onHover { hovering = $0 }
            .animation(DesignTokens.quick, value: configuration.isPressed)
    }
    private var foreground: Color {
        switch kind {
        case .primary: DesignTokens.paper
        case .record, .stop: .white
        case .secondary, .quiet: DesignTokens.ink
        }
    }
    private var background: Color {
        switch kind {
        case .primary: DesignTokens.ink
        case .record, .stop: DesignTokens.ember
        case .secondary: DesignTokens.surface
        case .quiet: hovering ? DesignTokens.hover : .clear
        }
    }
}

extension ButtonStyle where Self == HushButtonStyle {
    static var hushPrimary: HushButtonStyle { HushButtonStyle(kind: .primary) }
    static var hushSecondary: HushButtonStyle { HushButtonStyle(kind: .secondary) }
    static var hushQuiet: HushButtonStyle { HushButtonStyle(kind: .quiet) }
}

/// A small borderless icon button with hover feedback.
struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 26)
                .foregroundStyle(active ? DesignTokens.ink : DesignTokens.soft)
                .background(active || hovering ? DesignTokens.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

// MARK: Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = DesignTokens.inset
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous).strokeBorder(DesignTokens.hairline))
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: AnyView? = nil
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(DesignTokens.label).tracking(0.6).foregroundStyle(DesignTokens.faint)
    }
}

struct Chip: View {
    let symbol: String?
    let text: String
    var tint: Color = DesignTokens.soft
    init(_ text: String, symbol: String? = nil, tint: Color = DesignTokens.soft) { self.text = text; self.symbol = symbol; self.tint = tint }
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .medium)) }
            Text(text).lineLimit(1)
        }
        .font(DesignTokens.small).foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(DesignTokens.selected, in: Capsule())
    }
}

struct KeyHint: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys).font(.system(size: 11, weight: .medium).monospaced())
            .foregroundStyle(DesignTokens.faint)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DesignTokens.hairline))
    }
}

/// The ember dot. Breathes while recording unless Reduce Motion is on.
struct RecordingDot: View {
    var size: CGFloat = DesignTokens.dot
    var breathing = true
    @Environment(\.hushReduceMotion) private var reduceMotion
    @State private var inhale = false
    var body: some View {
        Circle().fill(DesignTokens.ember).frame(width: size, height: size)
            .scaleEffect(breathing && !reduceMotion && inhale ? DesignTokens.breathScale : 1)
            .animation(breathing && !reduceMotion ? .easeInOut(duration: DesignTokens.breathDuration / 2).repeatForever(autoreverses: true) : nil, value: inhale)
            .onAppear { inhale = true }
            .accessibilityHidden(true)
    }
}

/// Thin progress line. Indeterminate when there's no fraction.
struct ProgressLine: View {
    var fraction: Double?
    var body: some View {
        Group {
            if let fraction { ProgressView(value: fraction) } else { ProgressView() }
        }
        .progressViewStyle(.linear).tint(DesignTokens.ink.opacity(0.7)).controlSize(.small)
    }
}

// MARK: Banners

struct BannerStack: View {
    @Bindable var state: AppState
    var compact = false
    var body: some View {
        VStack(spacing: DesignTokens.space) {
            ForEach(state.banners) { banner in
                BannerView(banner: banner, compact: compact) { state.dismiss(banner.id) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(DesignTokens.spring, value: state.banners.map(\.id))
    }
}

struct BannerView: View {
    let banner: Banner
    var compact = false
    let dismiss: () -> Void
    private var symbol: String {
        switch banner.kind {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.circle"
        }
    }
    private var tint: Color {
        switch banner.kind {
        case .info: DesignTokens.soft
        case .success: DesignTokens.sage
        case .warning: DesignTokens.amber
        case .error: DesignTokens.ember
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.gap) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 14, weight: .medium)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title).font(DesignTokens.chromeStrong).fixedSize(horizontal: false, vertical: true)
                if let detail = banner.detail {
                    Text(detail).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                        .lineLimit(compact ? 3 : 6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Spacer(minLength: DesignTokens.space)
            if let title = banner.actionTitle, let action = banner.action {
                Button(title) { action(); dismiss() }.buttonStyle(HushButtonStyle(kind: .secondary)).controlSize(.small)
            }
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(DesignTokens.faint).help("Dismiss").padding(.top, 3)
        }
        .padding(.horizontal, DesignTokens.gap).padding(.vertical, 10)
        .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.radius + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius + 2, style: .continuous).strokeBorder(tint.opacity(0.35)))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Text helpers

/// Renders a search excerpt with matched words emphasised.
struct HighlightedText: View {
    let text: String
    var body: some View {
        Text(Self.attributed(text)).lineLimit(2)
    }
    static func attributed(_ raw: String) -> AttributedString {
        var result = AttributedString()
        var highlighted = false
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            var part = AttributedString(buffer)
            if highlighted {
                part.foregroundColor = DesignTokens.ink
                part.font = DesignTokens.small.weight(.semibold)
                part.backgroundColor = DesignTokens.amber.opacity(0.18)
            }
            result += part; buffer = ""
        }
        for character in raw {
            if String(character) == SearchHit.open { flush(); highlighted = true }
            else if String(character) == SearchHit.close { flush(); highlighted = false }
            else { buffer.append(character) }
        }
        flush()
        return result
    }
}

extension TimeInterval {
    /// "45 min", "1 h 5 min", "40 s".
    var spoken: String {
        let total = Int(self.rounded())
        if total < 60 { return "\(total) s" }
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }
}

extension Date {
    /// "Today", "Yesterday", "Monday", or "Oct 3".
    var relativeDay: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if calendar.isDateInTomorrow(self) { return "Tomorrow" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: .now)).day, days > 0, days < 7 {
            return formatted(.dateTime.weekday(.wide))
        }
        let sameYear = calendar.component(.year, from: self) == calendar.component(.year, from: .now)
        return sameYear ? formatted(.dateTime.month(.abbreviated).day()) : formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// A status glyph for a meeting row.
struct MeetingStatusMark: View {
    let meeting: Meeting
    let state: AppState
    var body: some View {
        if state.currentID == meeting.id && state.capture.isRecording {
            RecordingDot(size: 7)
        } else if state.isQueued(meeting.id) || meeting.isProcessing {
            ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
        } else if meeting.state == .failed {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(DesignTokens.amber)
        }
    }
}
