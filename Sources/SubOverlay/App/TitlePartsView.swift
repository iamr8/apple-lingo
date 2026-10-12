import SubOverlayCore
import SwiftUI

/// Text for the parts of a title.
enum TitlePartsText {
    /// m:ss, or h:mm:ss from an hour, as the player shows.
    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func name(_ kind: TitlePart.Kind) -> String {
        switch kind {
        case .intro: "Intro"
        case .recap: "Recap"
        case .content: "Content"
        case .after: "After content"
        }
    }

    /// From the first line's start to the last line's end.
    static func span(_ cues: [Cue]) -> String? {
        guard let start = cues.map(\.start).min(), let end = cues.map(\.end).max() else { return nil }
        return "\(clock(start)) - \(clock(end))"
    }
}

/// A bar of the title's parts, with a list of their times and where the translation runs.
struct TitlePartsView: View {
    let entry: SubtitleLibrary.Entry
    let parts: [TitlePart]

    @State private var span: String?

    var body: some View {
        let total = parts.map { $0.start + $0.duration }.max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ForEach(parts.indices, id: \.self) { i in
                    Rectangle().fill(Self.color(parts[i].kind))
                        .frame(width: max(2, geo.size.width * parts[i].duration / total), height: 10)
                        .offset(x: geo.size.width * parts[i].start / total)
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            ForEach(parts.indices, id: \.self) { i in
                HStack {
                    Circle().fill(Self.color(parts[i].kind)).frame(width: 8, height: 8)
                    Text(TitlePartsText.name(parts[i].kind))
                    Spacer()
                    Text("\(TitlePartsText.clock(parts[i].start)), \(TitlePartsText.clock(parts[i].duration)) long")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let target = entry.meta.targetLanguage, let span {
                Text("Your \(Languages.name(target)) lines: \(span)").font(.callout)
            }
            if parts.contains(where: { $0.kind == .intro || $0.kind == .recap }) {
                Text("Times are from the download. The TV app can show another intro or recap on each play, so the player's times can be later.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: entry.meta.targetLanguage) {
            span = entry.meta.targetLanguage.flatMap { try? entry.cues(language: $0) }.flatMap(TitlePartsText.span)
        }
    }

    static func color(_ kind: TitlePart.Kind) -> Color {
        switch kind {
        case .intro: .gray
        case .recap: .orange
        case .content: .accentColor
        case .after: .gray.opacity(0.5)
        }
    }
}
