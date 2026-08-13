import Foundation

public enum WorkbenchHoverPolicy {
  public static let transitionDuration = 0.12

  public static func backgroundOpacity(isHovering: Bool, isSelected: Bool = false) -> Double {
    if isSelected {
      return 0.18
    }
    return isHovering ? 0.14 : 0
  }

  public static func borderOpacity(isHovering: Bool, isSelected: Bool = false) -> Double {
    if isSelected {
      return 0.72
    }
    return isHovering ? 0.42 : 0
  }

  public static func shadowOpacity(isHovering: Bool, isSelected: Bool = false) -> Double {
    if isSelected {
      return 0.12
    }
    return isHovering ? 0.08 : 0
  }
}
