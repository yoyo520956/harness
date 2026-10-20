import SwiftUI

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(UIColor(hex: hex))
    }
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

/// DeepSeek Harness 官方 token（研究规格 harness-ui.md §4，亮/暗全对照）
final class HarnessTheme: ObservableObject {
    static let shared = HarnessTheme()

    // 语义别名（亮 / 暗）
    let bgBase = Color(light: 0xFFFFFF, dark: 0x151517)          // 画布底
    let layer2 = Color(light: 0xFFFFFF, dark: 0x2C2C2E)          // 卡片/抬升面
    let sidebarFill = Color(light: 0xF9FAFB, dark: 0x1B1B1C)     // 侧栏底
    let navActive = Color(light: 0xEBEEF2, dark: 0x434549)       // 选中项
    let ink = Color(light: 0x0F1115, dark: 0xF9FAFB)             // 主按钮墨色 / label-primary
    let blue = Color(light: 0x4176E6, dark: 0x7AAAFF)            // 业务蓝：发送/链接/光标
    let blueDeep = Color(light: 0x5686FE, dark: 0x5686FE)        // 发送键悬停加深
    let labelSecondary = Color(light: 0x61666B, dark: 0xCFD3D6)
    let labelTertiary = Color(light: 0x81858C, dark: 0xADB2B8)
    let labelCaption = Color(light: 0xADB2B8, dark: 0x81858C)    // 占位符/时间戳
    let bubbleUser = Color(light: 0xEDF3FE, dark: 0x2C2C2E)      // 用户气泡
    let bubbleHighlight = Color(light: 0xD3E2FF, dark: 0x434549) // 引用高亮
    let composerFill = Color(light: 0xFFFFFF, dark: 0x2C2C2E)    // 输入卡
    let codeBg = Color(light: 0xF9FAFB, dark: 0x1B1B1C)          // 代码块底
    let toast = Color(light: 0x353638, dark: 0x434549)
    let success = Color(hex: 0x22C55E)
    let error = Color(light: 0xEC1313, dark: 0xF25A5A)
    let warn = Color(hex: 0xF59E0B)
    let hairline = Color.primary.opacity(0.14)                    // 0.5px 发丝线

    // 圆角体系（radius 4/8/12/16/20/28，superellipse → .continuous）
    static let r4: CGFloat = 4
    static let r8: CGFloat = 8
    static let r12: CGFloat = 12
    static let r16: CGFloat = 16
    static let r20: CGFloat = 20
    static let r28: CGFloat = 28
}
