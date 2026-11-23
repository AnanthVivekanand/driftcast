import SwiftUI

/// A video's name on one line, cleaned of its release name. When space runs short only the
/// name is shortened, so the episode's number (or the film's year) stays readable:
/// "The Sopr… S4 E7" rather than "The.Sopr…265-RARBG".
struct TitleLine: View {
    let title: MediaTitle
    /// The name the person typed for the video, shown whole in place of the cleaned one.
    var name: String? = nil
    /// An episode's own name ("Pilot"), put after the cleaned name: "Breaking Bad S1 E1 · Pilot"
    /// (the user's request, 2026-11-22; it was only in the line under the name). Not shown
    /// with a name the person typed, which is shown as typed.
    var episodeName: String? = nil

    init(title: MediaTitle, name: String? = nil, episodeName: String? = nil) {
        self.title = title
        self.name = name
        self.episodeName = episodeName
    }

    /// The video as it is named everywhere: what the person called it, else what its file says.
    init(item: MediaItem, episodeName: String? = nil) {
        self.init(title: item.parsedTitle, name: item.givenName, episodeName: episodeName)
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
                    .layoutPriority(1)   // the episode's name gives way first
                if let tag = title.titleTag {
                    // The space travels with the tag so the two read as one line of text.
                    Text(" " + tag)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let episodeName, !episodeName.isEmpty {
                    Text(" · " + episodeName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
