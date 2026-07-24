import SwiftUI

enum Theme {
    // 간격
    static let s1: CGFloat = 6
    static let s2: CGFloat = 10
    static let s3: CGFloat = 16
    // 모서리
    static let radius: CGFloat = 8
    // 색
    static let accent = Color.accentColor
    static let panelBG = Color(nsColor: .windowBackgroundColor)
    static let selectionBG = Color.accentColor.opacity(0.18)
    static let overlayBG = Color.black.opacity(0.55)
    static let hairline = Color.white.opacity(0.08)
}
