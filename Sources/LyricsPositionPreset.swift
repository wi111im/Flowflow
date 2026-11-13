import AppKit

enum LyricsPositionPreset: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, center, bottomLeft, bottomCenter, bottomRight
    var id: String { rawValue }
    static let selectionKey = "floatingLyrics.positionPreset"
    var title: String {
        switch self {
        case .topLeft: "左上角"
        case .topCenter: "中上"
        case .topRight: "右上角"
        case .center: "正中间"
        case .bottomLeft: "左下角"
        case .bottomCenter: "中下"
        case .bottomRight: "右下角"
        }
    }
    var cell: (Int, Int) {
        switch self {
        case .topLeft: (0, 0)
        case .topCenter: (1, 0)
        case .topRight: (2, 0)
        case .center: (1, 1)
        case .bottomLeft: (0, 2)
        case .bottomCenter: (1, 2)
        case .bottomRight: (2, 2)
        }
    }
    var icon: NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            let (selectedX, selectedY) = self.cell
            for y in 0..<3 { for x in 0..<3 {
                let box = NSRect(x: CGFloat(1 + x * 5), y: CGFloat(1 + y * 5), width: 3.5, height: 3.5)
                let path = NSBezierPath(roundedRect: box, xRadius: 0.8, yRadius: 0.8)
                NSColor.labelColor.set()
                if x == selectedX && y == selectedY { path.fill() }
                else { path.lineWidth = 0.9; path.stroke() }
            } }
            return true
        }
        image.isTemplate = true
        return image
    }
    // Returns the movement needed to align the visible lyric content itself.
    func displacement(ink: NSRect, screen: NSRect, visible: NSRect,
                      topLimit: CGFloat, bottomInset: CGFloat, topCenterInset: CGFloat = 50) -> NSPoint {
        let (x, y) = cell
        let horizontalInset: CGFloat = 19
        let targetX = x == 0 ? screen.minX + horizontalInset
            : x == 2 ? screen.maxX - horizontalInset : screen.midX
        let currentX = x == 0 ? ink.minX : x == 2 ? ink.maxX : ink.midX
        let currentY = y == 0 ? ink.maxY : y == 2 ? ink.minY : ink.midY
        let targetY: CGFloat
        if y == 0 {
            targetY = x == 1 ? screen.maxY - topCenterInset : screen.maxY - 23
        } else if y == 2 {
            targetY = x == 1 ? visible.minY + 18 : screen.minY + bottomInset
        } else {
            targetY = visible.midY
        }
        return NSPoint(x: targetX - currentX, y: targetY - currentY)
    }
}
