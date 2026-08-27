import AppKit

/// Where the hardware notch actually is, and what to do on Macs that have none.
struct NotchGeometry {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main!
        let inset = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let measured = screen.frame.width - left - right
        let hasNotch = inset > 0 && left > 0 && right > 0
        return NotchGeometry(
            screen: screen,
            notchWidth: hasNotch ? measured : 180,
            notchHeight: hasNotch ? inset : 32,
            hasNotch: hasNotch
        )
    }

    /// Frame for the window, in screen coordinates, sized to hold the expanded panel.
    func windowFrame(expandedWidth: CGFloat, expandedHeight: CGFloat) -> NSRect {
        let width = max(expandedWidth, notchWidth)
        let frame = screen.frame
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - expandedHeight,
            width: width,
            height: expandedHeight
        )
    }
}
