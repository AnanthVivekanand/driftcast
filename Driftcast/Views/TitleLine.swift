import SwiftUI

/// A video's name on one line, cleaned of its release name. When space runs short only the
/// name is shortened, so the episode's number (or the film's year) stays readable:
/// "The Sopr… S4 E7" rather than "The.Sopr…265-RARBG".
struct TitleLine: View {
    let title: MediaTitle
    /// The name the person typed for the video, shown whole in place of the cleaned one.
    var name: String? = nil

    init(title: MediaTitle, name: String? = nil) {
        self.title = title
        self.name = name
    }

    /// The video as it is named everywhere: what the person called it, else what its file says.
    init(item: MediaItem) {
        self.init(title: item.parsedTitle, name: item.givenName)
    }

    var body: some View {
        if let name {
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
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
}
