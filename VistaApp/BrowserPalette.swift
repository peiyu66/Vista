import SwiftUI

/// Isolated visual comparison only; does not override system tint, cursor, focus or hover rendering.
enum BrowserBluePalette {
    static let enabled = true
    static var selection:Color {enabled ? Color(red:149/255,green:168/255,blue:177/255):.accentColor}
    static var folder:Color {
        guard enabled else{return .blue}
        return Color(uiColor:UIColor { traits in
            traits.accessibilityContrast == .high
            ? UIColor(red:220/255,green:239/255,blue:247/255,alpha:1)
            : UIColor(red:194/255,green:218/255,blue:230/255,alpha:1)
        })
    }
    static var emphasis:Color {enabled ? Color(red:194/255,green:218/255,blue:230/255):.accentColor}
}
