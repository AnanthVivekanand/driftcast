import Foundation

/// What a film database knows about a video: poster, plot, people, ratings. For an episode the
/// show's details are filled in with the episode's own title, date and synopsis.
struct MovieDetails: Codable, Hashable, Sendable {
    struct Rating: Codable, Hashable, Sendable {
        /// "IMDb", "Rotten Tomatoes", "Metacritic", "TVmaze".
        var source: String
        /// As the source writes it: "8.3/10", "88%", "76/100".
        var value: String
    }

    var title: String
    var year: Int?
    var runtimeMinutes: Int?
    /// Age rating: "PG-13", "R", "TV-MA".
    var certificate: String?
    var genres: [String] = []
    var directors: [String] = []
    var writers: [String] = []
    var cast: [String] = []
    var synopsis: String?
    var posterURL: URL?
    var ratings: [Rating] = []
    /// Where the details came from: "Apple", "TVmaze", "OMDb".
    var source: String
    /// The title's page at the source.
    var link: URL?

    // Episodes
    var showTitle: String?
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    /// "2001-03-04", as the source gives it.
    var airDate: String?
    var episodeSynopsis: String?
    var episodeImageURL: URL?
    var network: String?

    init(title: String, source: String) {
        self.title = title
        self.source = source
    }

    var isEpisode: Bool { episode != nil }

    /// "Season 1, Episode 11" / "Episode 11".
    var episodeLabel: String? {
        guard let episode else { return nil }
        if let season { return "Season \(season), Episode \(episode)" }
        return "Episode \(episode)"
    }

    /// "2h 50m" / "48m".
    var runtimeText: String? {
        guard let m = runtimeMinutes, m > 0 else { return nil }
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// The year for a playlist row: a film's year, or the year an episode was first shown.
    /// An episode with no date has none, since the show's own year is that of its first season.
    var listYear: Int? {
        guard isEpisode else { return year }
        return airDate.flatMap(Self.year(in:))
    }

    /// The year in a date as a source writes it: "2002-11-03", "03 Nov 2002".
    static func year(in date: String) -> Int? {
        date.split(whereSeparator: { !$0.isNumber })
            .compactMap { $0.count == 4 ? Int($0) : nil }
            .first { (1880...2100).contains($0) }
    }
}
