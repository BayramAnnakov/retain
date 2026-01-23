import SwiftUI

// MARK: - Spacing System (8pt Grid)

/// Consistent spacing values based on 8-point grid system
enum Spacing {
    /// 2pt - Extra extra small (hairline)
    static let xxs: CGFloat = 2
    /// 4pt - Extra small (tight)
    static let xs: CGFloat = 4
    /// 8pt - Small (compact)
    static let sm: CGFloat = 8
    /// 12pt - Medium (standard)
    static let md: CGFloat = 12
    /// 16pt - Large (comfortable)
    static let lg: CGFloat = 16
    /// 24pt - Extra large (spacious)
    static let xl: CGFloat = 24
    /// 32pt - Extra extra large (generous)
    static let xxl: CGFloat = 32
    /// 48pt - Section spacing
    static let section: CGFloat = 48
}

// MARK: - Corner Radius

/// Consistent corner radius values
enum CornerRadius {
    /// 4pt - Small elements (badges, chips)
    static let sm: CGFloat = 4
    /// 6pt - Standard elements (buttons, inputs)
    static let md: CGFloat = 6
    /// 8pt - Cards, panels
    static let lg: CGFloat = 8
    /// 12pt - Large cards, modals
    static let xl: CGFloat = 12
    /// Full capsule
    static let capsule: CGFloat = .infinity
}

// MARK: - Typography

/// Typography styles following Apple HIG
struct AppFont {
    // Headers
    static let largeTitle = Font.system(size: 26, weight: .bold)
    static let title = Font.system(size: 22, weight: .bold)
    static let title2 = Font.system(size: 17, weight: .semibold)
    static let title3 = Font.system(size: 15, weight: .semibold)

    // Body
    static let headline = Font.system(size: 13, weight: .semibold)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let body = Font.system(size: 13, weight: .regular)
    static let callout = Font.system(size: 12, weight: .regular)
    static let subheadline = Font.system(size: 11, weight: .regular)

    // Captions
    static let caption = Font.system(size: 11, weight: .regular)
    static let caption2 = Font.system(size: 10, weight: .regular)

    // Code
    static let code = Font.system(size: 12, design: .monospaced)
    static let codeSmall = Font.system(size: 11, design: .monospaced)
}

// MARK: - Provider Colors

extension Provider {
    /// Brand color for each provider - derived from registry
    var brandColor: Color {
        // Use registry configuration if available
        if let config = configuration {
            return config.brandColor
        }
        // Fallback for unknown providers
        return .gray
    }

    /// Short name for compact display
    var shortName: String {
        switch self {
        case .claudeCode: return "Code"
        case .claudeWeb: return "Claude"
        case .chatgptWeb: return "ChatGPT"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .geminiCLI: return "GemCLI"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        }
    }
}

// MARK: - Semantic Colors

struct AppColors {
    // Status colors (for backgrounds/icons)
    static let pending = Color.orange
    static let approved = Color.green
    static let rejected = Color.red
    static let error = Color.red

    // MARK: - WCAG AA Compliant Status Text Colors
    // These darker variants meet 4.5:1 contrast ratio on white backgrounds

    /// Dark green for text - meets WCAG AA (4.5:1 contrast on white)
    static let statusGreenText = Color(red: 0.11, green: 0.48, blue: 0.23)  // #1D7A3B

    /// Dark orange/amber for text - meets WCAG AA (4.5:1 contrast on white)
    static let statusOrangeText = Color(red: 0.60, green: 0.36, blue: 0.0)  // #9A5B00

    /// Dark red for text - meets WCAG AA (4.5:1 contrast on white)
    static let statusRedText = Color(red: 0.70, green: 0.15, blue: 0.15)  // #B32626

    /// Returns accessible text color for status, adapts to color scheme
    static func statusTextColor(_ status: StatusType, colorScheme: ColorScheme) -> Color {
        // In dark mode, the standard colors have sufficient contrast
        if colorScheme == .dark {
            switch status {
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            case .info: return .blue
            }
        }
        // In light mode, use darker variants for WCAG compliance
        switch status {
        case .success: return statusGreenText
        case .warning: return statusOrangeText
        case .error: return statusRedText
        case .info: return .blue
        }
    }

    enum StatusType {
        case success, warning, error, info
    }

    // UI colors
    static let separator = Color(NSColor.separatorColor)
    static let background = Color(NSColor.windowBackgroundColor)
    static let secondaryBackground = Color(NSColor.controlBackgroundColor)
    static let tertiaryBackground = Color(NSColor.textBackgroundColor)

    // Text colors
    static let primaryText = Color(NSColor.labelColor)
    static let secondaryText = Color(NSColor.secondaryLabelColor)
    static let tertiaryText = Color(NSColor.tertiaryLabelColor)

    // MARK: - Environment-Aware Colors (Dark Mode Optimized)

    /// Card background with optimal contrast for both modes
    static func cardBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(white: 0.15)
            : Color(NSColor.controlBackgroundColor)
    }

    /// Elevated surface for floating elements
    static func elevatedSurface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(white: 0.18)
            : Color.white
    }

    /// Subtle divider that's visible in both modes
    static func subtleDivider(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.08)
    }

    /// Hover highlight with good visibility
    static func hoverHighlight(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.05)
    }

    /// Selection background for list items
    static func selectionBackground(_ colorScheme: ColorScheme) -> Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.25 : 0.15)
    }
}

// MARK: - Icon Sizes

enum IconSize {
    /// 12pt - Inline icons
    static let xs: CGFloat = 12
    /// 14pt - Small icons
    static let sm: CGFloat = 14
    /// 16pt - Standard icons
    static let md: CGFloat = 16
    /// 20pt - Sidebar icons
    static let lg: CGFloat = 20
    /// 24pt - Header icons
    static let xl: CGFloat = 24
    /// 32pt - Empty state icons
    static let xxl: CGFloat = 32
    /// 48pt - Large empty state icons
    static let hero: CGFloat = 48
}

// MARK: - Column Widths

enum ColumnWidth {
    // Sidebar (first column)
    static let sidebarMin: CGFloat = 220
    static let sidebarIdeal: CGFloat = 260
    static let sidebarMax: CGFloat = 300

    // Content list (second column) - wider for better conversation scanning
    static let contentMin: CGFloat = 320     // +40pt
    static let contentIdeal: CGFloat = 380   // +40pt
    static let contentMax: CGFloat = 450     // +50pt

    // Detail (third column) - flexible, slightly reduced min
    static let detailMin: CGFloat = 380      // -20pt (detail compresses first)
}

// MARK: - View Extensions

extension View {
    /// Apply standard card styling
    func cardStyle() -> some View {
        self
            .background(AppColors.secondaryBackground)
            .cornerRadius(CornerRadius.lg)
    }

    /// Apply hover effect
    func hoverEffect(_ isHovering: Bool) -> some View {
        self
            .background(isHovering ? Color.accentColor.opacity(0.08) : Color.clear)
            .cornerRadius(CornerRadius.md)
    }

    /// Standard list row padding
    func listRowPadding() -> some View {
        self.padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
    }

    /// Apply environment-aware card styling (dark mode optimized)
    func adaptiveCardStyle(_ colorScheme: ColorScheme) -> some View {
        self
            .background(AppColors.cardBackground(colorScheme))
            .cornerRadius(CornerRadius.lg)
    }

    /// Apply environment-aware elevated surface
    func elevatedStyle(_ colorScheme: ColorScheme) -> some View {
        self
            .background(AppColors.elevatedSurface(colorScheme))
            .cornerRadius(CornerRadius.lg)
            .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.08), radius: 4, y: 2)
    }

    /// Standardized focus ring for accessibility
    /// Use this on all focusable elements for consistent keyboard navigation
    func focusRing(_ isFocused: Bool, cornerRadius: CGFloat = CornerRadius.md) -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    /// Focus ring with padding offset (for elements that need the ring outside their bounds)
    func focusRingOutset(_ isFocused: Bool, cornerRadius: CGFloat = CornerRadius.md, offset: CGFloat = 2) -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius + offset)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(-offset)
                    .opacity(isFocused ? 1 : 0)
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Skeleton Loading

/// Shimmer animation for skeleton loading states
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(colors: [
                        .clear,
                        .white.opacity(0.3),
                        .clear
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .offset(x: phase * 400 - 200)
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    /// Apply shimmer loading animation
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

/// Skeleton placeholder for loading states
struct SkeletonView: View {
    var width: CGFloat? = nil
    var height: CGFloat = 16
    var cornerRadius: CGFloat = CornerRadius.sm

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.gray.opacity(0.2))
            .frame(width: width, height: height)
            .shimmer()
    }
}

/// Skeleton row for list loading states
struct SkeletonRow: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Icon placeholder
            SkeletonView(width: IconSize.lg, height: IconSize.lg, cornerRadius: IconSize.lg / 2)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Title placeholder
                SkeletonView(width: 120, height: 14)
                // Subtitle placeholder
                SkeletonView(width: 80, height: 10)
            }

            Spacer()

            // Badge placeholder
            SkeletonView(width: 40, height: 12, cornerRadius: CornerRadius.capsule)
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md)
    }
}

/// List skeleton with multiple rows
struct SkeletonList: View {
    var rowCount: Int = 5

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { _ in
                SkeletonRow()
                Divider()
            }
        }
    }
}

// MARK: - Smart Folder Types

/// Smart folder categories for sidebar
enum SmartFolder: String, CaseIterable, Identifiable {
    case today = "Today"
    case thisWeek = "This Week"
    case withLearnings = "With Learnings"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .today: return "calendar"
        case .thisWeek: return "calendar.badge.clock"
        case .withLearnings: return "lightbulb.fill"
        }
    }

    var color: Color {
        switch self {
        case .today: return .blue
        case .thisWeek: return .cyan
        case .withLearnings: return .orange
        }
    }
}
