import CoreGraphics
import CoreText
import Foundation
import MediaAccessibility

public struct RGBA: Sendable, Equatable {
    public var r, g, b, a: Double

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ color: CGColor) {
        let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [1, 1, 1, 1]
        self.init(r: c[0], g: c[1], b: c[2], a: c.count > 3 ? c[3] : 1)
    }
}

/// Values as the MediaAccessibility API returns them.
public struct RawCaptionAppearance: Sendable, Equatable {
    public var fontName: String
    public var relativeSize: Double
    public var text: RGBA
    public var textOpacity: Double
    public var background: RGBA
    public var backgroundOpacity: Double
    public var window: RGBA
    public var windowOpacity: Double
    public var windowCornerRadius: Double
    public var edgeStyle: Int

    /// Reads the user's caption settings. Our cues carry no color styling,
    /// so `useContentIfAvailable` resolves to the preference value.
    public static func current() -> RawCaptionAppearance {
        let d = MACaptionAppearanceDomain.user
        var b = MACaptionAppearanceBehavior.useValue
        let font = MACaptionAppearanceCopyFontDescriptorForStyle(d, &b, .default).takeRetainedValue()
        let name = CTFontDescriptorCopyAttribute(font, kCTFontNameAttribute) as? String ?? ".AppleSystemUIFontMedium"
        return RawCaptionAppearance(
            fontName: name,
            relativeSize: MACaptionAppearanceGetRelativeCharacterSize(d, &b),
            text: RGBA(MACaptionAppearanceCopyForegroundColor(d, &b).takeRetainedValue()),
            textOpacity: MACaptionAppearanceGetForegroundOpacity(d, &b),
            background: RGBA(MACaptionAppearanceCopyBackgroundColor(d, &b).takeRetainedValue()),
            backgroundOpacity: MACaptionAppearanceGetBackgroundOpacity(d, &b),
            window: RGBA(MACaptionAppearanceCopyWindowColor(d, &b).takeRetainedValue()),
            windowOpacity: MACaptionAppearanceGetWindowOpacity(d, &b),
            windowCornerRadius: MACaptionAppearanceGetWindowRoundedCornerRadius(d, &b),
            edgeStyle: MACaptionAppearanceGetTextEdgeStyle(d, &b).rawValue
        )
    }

    /// Darwin notification posted when the user changes caption settings.
    public static let changedNotification = kMACaptionAppearanceSettingsChangedNotification as String
}

/// Caption look ready for drawing. Opacity is folded into each color's alpha.
public struct CaptionStyle: Sendable, Equatable {
    public enum Edge: Sendable, Equatable { case none, raised, depressed, uniform, dropShadow }

    /// Font size relative to the video height at relative size 1, measured from Apple's captions.
    public static let sizeFactor = 0.03015
    /// Line pitch relative to the font size, measured from Apple's two-line captions.
    public static let lineHeightFactor = 1.452
    /// How far text is drawn above its block's top inset, relative to the font size, so the first
    /// line's ink sits where Apple's does (0.31 em below the cue's `line` position).
    public static let textRaise = 0.331
    /// Apple keeps caption blocks this share of the video height below the top edge
    /// (measured on a `line:0%` cue). The bottom margin is not measured, so none is applied.
    public static let topMargin = 0.05

    public var fontName: String
    public var relativeSize: Double
    public var text: RGBA
    public var background: RGBA
    public var window: RGBA
    public var windowCornerRadius: Double
    public var edge: Edge

    public init(_ raw: RawCaptionAppearance) {
        fontName = raw.fontName
        relativeSize = raw.relativeSize
        text = Self.fold(raw.text, raw.textOpacity)
        background = Self.fold(raw.background, raw.backgroundOpacity)
        window = Self.fold(raw.window, raw.windowOpacity)
        windowCornerRadius = raw.windowCornerRadius
        edge = switch raw.edgeStyle {
        case 2: .raised
        case 3: .depressed
        case 4: .uniform
        case 5: .dropShadow
        default: .none
        }
    }

    public func fontSize(videoHeight: Double) -> Double {
        videoHeight * Self.sizeFactor * relativeSize
    }

    private static func fold(_ c: RGBA, _ opacity: Double) -> RGBA {
        RGBA(r: c.r, g: c.g, b: c.b, a: c.a * opacity)
    }
}
