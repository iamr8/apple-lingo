import AppKit
import SubOverlayCore

/// Draws the active cues in the user's caption style. Redraws only when an input changes.
final class CaptionView: NSView {
    var cues: [Cue] = [] { didSet { if cues != oldValue { needsDisplay = true } } }
    var style = CaptionStyle(RawCaptionAppearance.current()) { didSet { if style != oldValue { needsDisplay = true } } }
    var rightToLeft = false { didSet { if rightToLeft != oldValue { needsDisplay = true } } }
    /// Vertical shift in percent of the video height. Positive moves captions down.
    var nudge = 0.0 { didSet { if nudge != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard !cues.isEmpty, bounds.height > 0 else { return }
        let fontSize = style.fontSize(videoHeight: bounds.height)
        let padding = CGSize(width: fontSize * 0.3, height: fontSize * 0.12)
        let texts = cues.map { attributed($0, fontSize: fontSize) }
        let blocks = zip(cues, texts).map { cue, text in
            let size = measure(text, maxLines: 2, lineHeight: fontSize * CaptionStyle.lineHeightFactor)
            return (cue.layout, CGSize(width: size.width + padding.width * 2, height: size.height + padding.height * 2))
        }
        let frames = VideoGeometry.stackFrames(blocks, video: bounds.size, nudge: nudge, gap: fontSize * 0.1)
        for (text, frame) in zip(texts, frames) {
            if style.window.a > 0 {
                color(style.window).setFill()
                let r = style.windowCornerRadius
                // Even space above and below the ink; Apple's box is not measured yet (needs a bright scene).
                var box = frame
                box.size.height -= fontSize * 0.18
                NSBezierPath(roundedRect: box, xRadius: r, yRadius: r).fill()
            }
            text.draw(with: frame.insetBy(dx: padding.width, dy: padding.height).offsetBy(dx: 0, dy: -fontSize * CaptionStyle.textRaise),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    func attributed(_ cue: Cue, fontSize: CGFloat) -> NSAttributedString {
        var font = NSFont(name: style.fontName, size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .medium)
        // Persian and Arabic fonts have no true italic; a slanted script reads badly.
        if cue.italic && !rightToLeft {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: fontSize) ?? font
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.baseWritingDirection = rightToLeft ? .rightToLeft : .natural
        paragraph.minimumLineHeight = fontSize * CaptionStyle.lineHeightFactor
        paragraph.maximumLineHeight = fontSize * CaptionStyle.lineHeightFactor
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color(style.text),
            .paragraphStyle: paragraph,
        ]
        if style.background.a > 0 { attrs[.backgroundColor] = color(style.background) }
        let edgeColor = NSColor.black.withAlphaComponent(style.text.a)
        switch style.edge {
        case .none:
            break
        case .uniform:
            attrs[.strokeColor] = edgeColor
            attrs[.strokeWidth] = -3.0
        case .dropShadow:
            attrs[.shadow] = shadow(offset: CGSize(width: fontSize * 0.05, height: -fontSize * 0.05), blur: fontSize * 0.08, color: edgeColor)
        case .raised:
            attrs[.shadow] = shadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: 0, color: edgeColor)
        case .depressed:
            attrs[.shadow] = shadow(offset: CGSize(width: 0, height: fontSize * 0.04), blur: 0, color: edgeColor)
        }
        return NSAttributedString(string: cue.text, attributes: attrs)
    }

    /// Text size within 80% of the video width; widens up to 95% to keep `maxLines` lines.
    private func measure(_ text: NSAttributedString, maxLines: Int, lineHeight: CGFloat) -> CGSize {
        var size = CGSize.zero
        for fraction in [0.8, 0.9, 0.95] {
            let rect = text.boundingRect(with: CGSize(width: bounds.width * fraction, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
            size = CGSize(width: ceil(rect.width), height: ceil(rect.height))
            if size.height <= lineHeight * CGFloat(maxLines) { break }
        }
        return size
    }

    private func shadow(offset: CGSize, blur: CGFloat, color: NSColor) -> NSShadow {
        let s = NSShadow()
        s.shadowOffset = offset
        s.shadowBlurRadius = blur
        s.shadowColor = color
        return s
    }

    private func color(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
