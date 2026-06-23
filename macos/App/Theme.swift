import SwiftUI

enum Theme {
    // Severity thresholds (percent)
    static let warnPct = 70.0
    static let critPct = 90.0

    // Palette — matches the web "Status Board" (low-chroma dark instrument theme)
    static let bg        = Color(hex: 0x0e1014)
    static let panel     = Color(hex: 0x14171d)
    static let panel2    = Color(hex: 0x171b22)
    static let rowHover  = Color(hex: 0x181c24)
    static let hair      = Color(hex: 0x232830)
    static let hairSoft  = Color(hex: 0x1d2128)

    static let ink   = Color(hex: 0xe7eaef)
    static let ink2  = Color(hex: 0xaab3c0)
    static let ink3  = Color(hex: 0x6f7886)
    static let ink4  = Color(hex: 0x4a525e)

    static let calm    = Color(hex: 0x3a4250)   // neutral meter fill (fine)
    static let calmDim = Color(hex: 0x262b33)
    static let warn    = Color(hex: 0xd9a23a)   // amber 70-89%
    static let alarm   = Color(hex: 0xe5484d)   // red >=90%
    static let alarmBg = Color(hex: 0xe5484d).opacity(0.12)
    static let ok      = Color(hex: 0x4e8a64)
    static let accent  = Color(hex: 0x7c93b3)

    // numerals
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255.0,
                  green: Double((hex >> 8) & 0xff) / 255.0,
                  blue: Double(hex & 0xff) / 255.0,
                  opacity: 1.0)
    }
}
