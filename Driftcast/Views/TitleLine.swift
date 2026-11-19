import SwiftUI

/// A video's name on one line, cleaned of its release name. When space runs short only the
/// name is shortened, so the episode's number (or the film's year) stays readable:
/// "The Sopr… S4 E7" rather than "The.Sopr…265-RARBG".
struct TitleLine: View {
    let title: MediaTitle

    var body: some View {
        HStack(spacing: 0) {
            Text(title.title)
                .lineLimit(1)
                .truncationMode(.tail)
            if let tag = title.titleTag {
                // The space travels with the tag so the two read as one line of text.
                Text(" " + tag)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
