import AppKit

func menuBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        // Original monitor-body and focus-light brand geometry, monochrome for the menu bar.
        let transform = AffineTransform(m11: 0.025, m12: 0, m21: 0, m22: 0.025, tX: -3.8, tY: -4.3)
        let body = NSBezierPath(roundedRect: NSRect(x: 152, y: 244, width: 720, height: 488), xRadius: 48, yRadius: 48)
        body.append(NSBezierPath(roundedRect: NSRect(x: 178, y: 270, width: 668, height: 436), xRadius: 26, yRadius: 26))
        body.windingRule = .evenOdd
        body.transform(using: transform)
        NSColor.black.setFill()
        body.fill()

        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 454, y: 728))
        stand.line(to: NSPoint(x: 570, y: 728))
        stand.line(to: NSPoint(x: 570, y: 755))
        stand.curve(to: NSPoint(x: 612, y: 795), controlPoint1: NSPoint(x: 570, y: 775), controlPoint2: NSPoint(x: 581, y: 789))
        stand.line(to: NSPoint(x: 640, y: 795))
        stand.curve(to: NSPoint(x: 656, y: 811), controlPoint1: NSPoint(x: 648.84, y: 795), controlPoint2: NSPoint(x: 656, y: 802.16))
        stand.line(to: NSPoint(x: 656, y: 820))
        stand.line(to: NSPoint(x: 368, y: 820))
        stand.line(to: NSPoint(x: 368, y: 811))
        stand.curve(to: NSPoint(x: 384, y: 795), controlPoint1: NSPoint(x: 368, y: 802.16), controlPoint2: NSPoint(x: 375.16, y: 795))
        stand.line(to: NSPoint(x: 412, y: 795))
        stand.curve(to: NSPoint(x: 454, y: 755), controlPoint1: NSPoint(x: 443, y: 789), controlPoint2: NSPoint(x: 454, y: 775))
        stand.close()
        stand.transform(using: transform)
        stand.fill()

        let light = NSBezierPath()
        light.move(to: NSPoint(x: 198, y: 342))
        light.curve(to: NSPoint(x: 487, y: 686), controlPoint1: NSPoint(x: 301, y: 375), controlPoint2: NSPoint(x: 434, y: 495))
        light.line(to: NSPoint(x: 537, y: 686))
        light.curve(to: NSPoint(x: 826, y: 342), controlPoint1: NSPoint(x: 590, y: 495), controlPoint2: NSPoint(x: 723, y: 375))
        light.line(to: NSPoint(x: 826, y: 301))
        light.curve(to: NSPoint(x: 814, y: 289), controlPoint1: NSPoint(x: 826, y: 294.37), controlPoint2: NSPoint(x: 820.63, y: 289))
        light.line(to: NSPoint(x: 210, y: 289))
        light.curve(to: NSPoint(x: 198, y: 301), controlPoint1: NSPoint(x: 203.37, y: 289), controlPoint2: NSPoint(x: 198, y: 294.37))
        light.close()
        light.transform(using: transform)
        light.fill()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Extilume"
    return image
}
