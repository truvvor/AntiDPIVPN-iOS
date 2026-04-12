import SwiftUI

extension LinearGradient {
    /// Standard app background gradient (dark/light adaptive)
    static var appBackground: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [
                Color(UIColor { $0.userInterfaceStyle == .dark
                    ? UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
                    : UIColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1) }),
                Color(UIColor { $0.userInterfaceStyle == .dark
                    ? UIColor(red: 0.15, green: 0.11, blue: 0.15, alpha: 1)
                    : UIColor(red: 0.95, green: 0.93, blue: 0.98, alpha: 1) })
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
