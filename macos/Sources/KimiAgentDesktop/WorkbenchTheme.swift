import SwiftUI
import KimiAgentCore

enum WorkbenchTheme {
  static let canvas = Color(red: 0.9686, green: 0.9686, blue: 0.9569)
  static let content = Color(red: 0.9882, green: 0.9882, blue: 0.9804)
  static let sidebar = Color(red: 0.9451, green: 0.9490, blue: 0.9373)
  static let primaryText = Color(red: 0.1216, green: 0.1373, blue: 0.1569)
  static let secondaryText = Color(red: 0.4196, green: 0.4392, blue: 0.4706)
  static let border = Color(red: 0.8902, green: 0.8980, blue: 0.8863)
  static let accent = Color(red: 0.0980, green: 0.6627, blue: 0.5843)
  static let accentSurface = Color(red: 0.8980, green: 0.9569, blue: 0.9412)
  static let success = Color(red: 0.1490, green: 0.5412, blue: 0.3569)
  static let warning = Color(red: 0.7686, green: 0.4784, blue: 0.1020)
  static let destructive = Color(red: 0.7882, green: 0.2902, blue: 0.2902)

  static let smallRadius: CGFloat = 8
  static let controlRadius: CGFloat = 12
  static let floatingRadius: CGFloat = 16

  static let shortAnimation = Animation.easeOut(duration: 0.2)
}

struct WorkbenchSurface: ViewModifier {
  let color: Color
  let radius: CGFloat

  func body(content: Content) -> some View {
    content
      .background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(WorkbenchTheme.border.opacity(0.9), lineWidth: 1)
      }
  }
}

extension View {
  func workbenchSurface(
    color: Color = WorkbenchTheme.content,
    radius: CGFloat = WorkbenchTheme.controlRadius
  ) -> some View {
    modifier(WorkbenchSurface(color: color, radius: radius))
  }

  func workbenchHoverFeedback(
    radius: CGFloat = WorkbenchTheme.smallRadius,
    baseColor: Color = WorkbenchTheme.primaryText,
    hoverColor: Color = WorkbenchTheme.accent,
    isSelected: Bool = false
  ) -> some View {
    modifier(
      WorkbenchHoverFeedback(
        radius: radius,
        baseColor: baseColor,
        hoverColor: hoverColor,
        isSelected: isSelected
      )
    )
  }
}

private struct WorkbenchHoverFeedback: ViewModifier {
  let radius: CGFloat
  let baseColor: Color
  let hoverColor: Color
  let isSelected: Bool
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .foregroundStyle(isHovering ? hoverColor : baseColor)
      .background(
        (isSelected
          ? WorkbenchTheme.accentSurface.opacity(WorkbenchHoverPolicy.backgroundOpacity(isHovering: true, isSelected: true))
          : isHovering
            ? WorkbenchTheme.accent.opacity(WorkbenchHoverPolicy.backgroundOpacity(isHovering: true))
            : .clear),
        in: RoundedRectangle(cornerRadius: radius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(
            isSelected
              ? WorkbenchTheme.accent.opacity(WorkbenchHoverPolicy.borderOpacity(isHovering: true, isSelected: true))
              : isHovering
                ? WorkbenchTheme.accent.opacity(WorkbenchHoverPolicy.borderOpacity(isHovering: true))
                : WorkbenchTheme.border.opacity(WorkbenchHoverPolicy.borderOpacity(isHovering: false)),
            lineWidth: 1
          )
      }
      .shadow(
        color: (isHovering || isSelected)
          ? WorkbenchTheme.accent.opacity(WorkbenchHoverPolicy.shadowOpacity(isHovering: isHovering, isSelected: isSelected))
          : .clear,
        radius: isSelected ? 7 : 5,
        x: 0,
        y: 2
      )
      .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .onHover { hovering in
        withAnimation(.easeOut(duration: WorkbenchHoverPolicy.transitionDuration)) {
          isHovering = hovering
        }
      }
  }
}
