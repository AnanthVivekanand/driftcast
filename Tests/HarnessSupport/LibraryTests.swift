import Foundation

// Harness checks for the library, names made from files, typed names, the watched list, online details.
// Uses check(_:_:), spin, await_ and fetch from Helpers.swift, and the global mediaDir (the
// test media folder, from the command line) that harness.swift defines.
@MainActor func libraryTests() {
    let fm = FileManager.default
    // Resolved, as a folder's files come when it is dropped: the temporary folder is reached
    // through a link (/var is /private/var).
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("harness-library-\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    /// A folder of its own for one check, with empty files of these names in it.
    func folder(_ name: String, files: [String] = []) -> (URL, [URL]) {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = files.map { dir.appendingPathComponent($0) }
        urls.forEach { fm.createFile(atPath: $0.path, contents: Data()) }
        return (dir, urls)
    }
    func logged(_ phrase: String) -> Int {
        ErrorLog.flush()
        return ((try? String(contentsOf: ErrorLog.url, encoding: .utf8)) ?? "").components(separatedBy: phrase).count - 1
    }
    func modified(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
    func names(_ library: Library, _ id: Playlist.ID?) -> [String] {
        library.playlists.first { $0.id == id }?.items.map(\.url.lastPathComponent) ?? []
    }

    // MARK: Saved playlists that can't be read

    // A library file that is there but can't be opened is left as it is: the list starts empty,
    // nothing is saved over it, and the first change the person makes moves it aside first.
    do {
        let (dir, files) = folder("unreadable", files: ["Heat.1995.mkv"])
        let store = dir.appendingPathComponent("library.json")
        let first = Library(storeURL: store)
        let pl = first.newPlaylist(named: "Kept")
        first.add(files, to: pl)
        first.saveNow()
        let original = try! Data(contentsOf: store)
        try! fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)
        let before = logged("Playlists: reading them")
        let shut = Library(storeURL: store)
        let was = modified(store)
        spin(0.9)
        shut.saveNow()
        check(shut.loadProblem?.contains("couldn't open your saved playlists") == true && shut.playlists.map(\.name) == ["Playlist"]
              && modified(store) == was && logged("Playlists: reading them") == before + 1,
              "playlists that can't be opened: the list starts empty, the person is told, it is logged, and nothing is saved over them (\(shut.loadProblem ?? "no message"))")
        shut.newPlaylist(named: "New")
        shut.saveNow()
        let aside = dir.appendingPathComponent("library.unreadable.json")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: aside.path)
        let kept = try? Data(contentsOf: aside)
        let now = Library(storeURL: store)
        check(kept == original && now.playlists.map(\.name) == ["Playlist", "New"] && now.loadProblem == nil,
              "playlists that can't be opened: the first change moves the file aside whole, then the new list is saved (\(now.playlists.map(\.name)))")
    }

    // A library file that can't be decoded is set aside under a name nothing else has, logged,
    // and the person is told where it is.
    do {
        let (dir, _) = folder("undecodable")
        let store = dir.appendingPathComponent("library.json")
        try! Data("not a library".utf8).write(to: store)
        try! Data("an earlier one".utf8).write(to: dir.appendingPathComponent("library.unreadable.json"))
        let before = logged("Playlists: reading them")
        let library = Library(storeURL: store)
        let aside = dir.appendingPathComponent("library.unreadable 2.json")
        let earlier = try? String(contentsOf: dir.appendingPathComponent("library.unreadable.json"), encoding: .utf8)
        check((try? String(contentsOf: aside, encoding: .utf8)) == "not a library" && earlier == "an earlier one"
              && library.loadProblem?.contains("library.unreadable 2.json") == true && logged("Playlists: reading them") == before + 1,
              "playlists that can't be read: kept beside under a new name, the earlier copy left alone, logged and told (\(library.loadProblem ?? "no message"))")
    }

    // MARK: Adding, moving and the rest

    // Add Videos… with no playlist selected goes into the first playlist and shows it.
    do {
        let (dir, files) = folder("no-selection", files: ["Alien.1979.mkv"])
        let library = Library(storeURL: dir.appendingPathComponent("library.json"))
        let firstID = library.playlists.first?.id
        library.selection = nil
        let added = library.add(files)
        check(added.count == 1 && names(library, firstID) == ["Alien.1979.mkv"] && library.selection == firstID,
              "Add Videos… with no playlist selected adds to the first playlist and shows it (\(added.count) added)")
    }

    // Episodes added later go into their season's list in episode order, while the list is
    // still in that order; a list rearranged by hand gets them at the end.
    do {
        func e(_ n: Int) -> String { String(format: "The.Sopranos.S05E%02d.1080p.BluRay.x265-RARBG.mp4", n) }
        let (dir, files) = folder("later-episodes", files: (1...13).map(e))
        let library = Library(storeURL: dir.appendingPathComponent("library.json"))
        library.add(Array(files[10...12]))
        let season = library.playlists.first { $0.name == "The Sopranos S5" }?.id
        check(season != nil && names(library, season) == [e(11), e(12), e(13)], "three episodes make their season's playlist")
        let earlier = library.add([files[2], files[0], files[1]], to: season)
        check(earlier.count == 3 && names(library, season) == [e(1), e(2), e(3), e(11), e(12), e(13)],
              "earlier episodes added later go before the ones listed (\(names(library, season).map { String($0.dropFirst(16).prefix(3)) }))")
        // One episode on its own, dropped while another playlist is showing, joins its season in place.
        let other = library.newPlaylist(named: "Films")
        let one = library.add([files[6]], to: other)
        check(one.count == 1 && names(library, season) == [e(1), e(2), e(3), e(7), e(11), e(12), e(13)] && names(library, other).isEmpty,
              "one episode dropped elsewhere takes its place in its season's list")
        let last = library.add([files[3], files[4]], to: season)
        check(last.count == 2 && names(library, season) == [e(1), e(2), e(3), e(4), e(5), e(7), e(11), e(12), e(13)],
              "episodes between the ones listed go between them")
        // The same file again adds nothing and moves nothing.
        let again = library.add([files[0], files[12]], to: season)
        check(again.isEmpty && names(library, season).count == 9, "episodes already listed are not listed again")
        // Rearranged by hand: the order is the owner's, so new ones go at the end.
        if let season { library.move(in: season, from: IndexSet(integer: 0), to: 9) }
        check(names(library, season).last == e(1), "a row moved to the end by hand")
        library.add([files[7], files[8]], to: season)
        check(Array(names(library, season).suffix(3)) == [e(1), e(8), e(9)], "a list rearranged by hand gets new episodes at the end")
        check(Library.merged([], into: []).isEmpty, "nothing merged into nothing is nothing")
    }

    // Dropped below the playlists: a playlist of their own, named after them.
    do {
        func u(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
        check(Library.playlistName(for: [u("The.Sopranos.S04E12.1080p.mkv")]) == "The Sopranos S4", "one episode names its season: \(Library.playlistName(for: [u("The.Sopranos.S04E12.1080p.mkv")]) ?? "nil")")
        check(Library.playlistName(for: [u("The.Sopranos.S04E12.mkv"), u("The.Sopranos.S05E01.mkv")]) == "The Sopranos", "two seasons name the show")
        check(Library.playlistName(for: [u("Ronin.1998.1080p.BluRay.mkv")]) == "Ronin", "a film names itself: \(Library.playlistName(for: [u("Ronin.1998.1080p.BluRay.mkv")]) ?? "nil")")
        check(Library.playlistName(for: [u("Ronin.1998.mkv"), u("Heat.1995.mkv")]) == nil, "two films with nothing in common have no name")

        func e(_ n: Int, _ s: Int = 4) -> String { String(format: "The.Sopranos.S%02dE%02d.mkv", s, n) }
        let (dir, files) = folder("new-playlists", files: [e(12), e(7), e(8), e(1, 5), e(2, 5), "Ronin.1998.mkv", "Heat.1995.mkv"])
        let library = Library(storeURL: dir.appendingPathComponent("library.json"))
        let start = library.playlists.count
        let one = library.addToNewPlaylist([files[0]])
        let s4 = library.playlists.first { $0.name == "The Sopranos S4" }
        check(one.count == 1 && s4?.items.count == 1 && library.selection == s4?.id && library.playlists.count == start + 1,
              "the.sopranos.s04e12 dropped below the playlists makes The Sopranos S4 and shows it")
        library.addToNewPlaylist([files[1], files[2]])
        check(library.playlists.count == start + 1 && names(library, s4?.id) == [e(7), e(8), e(12)],
              "more of season 4 joins it, in episode order: \(names(library, s4?.id))")
        library.addToNewPlaylist([files[3], files[4]])
        check(names(library, library.playlists.first { $0.name == "The Sopranos S5" }?.id) == [e(1, 5), e(2, 5)] && library.playlists.count == start + 2,
              "two episodes of season 5 make The Sopranos S5: \(library.playlists.map(\.name))")
        library.addToNewPlaylist([files[5]])
        let ronin = library.playlists.first { $0.name == "Ronin" }
        check(ronin?.items.count == 1 && library.selection == ronin?.id, "a film makes a playlist of its own name")
        // One episode dropped on its own season's playlist goes to its place too.
        let (_, more) = folder("new-playlists-more", files: [e(1)])
        if let s4 { library.add(more, to: s4.id) }
        check(names(library, s4?.id).first == e(1), "an episode dropped on its season's playlist takes its place: \(names(library, s4?.id))")
        // A row dragged out of a mixed playlist below the playlists moves to one of its own.
        let mixed = library.newPlaylist(named: "Mixed")
        let heat = library.add([files[6]], to: mixed)
        library.moveToNewPlaylist(Set(heat.map(\.id)), from: mixed)
        let heatList = library.playlists.first { $0.name == "Heat" }
        check(names(library, mixed).isEmpty && heatList?.items.map(\.id) == heat.map(\.id) && library.selection == heatList?.id,
              "a row dragged below the playlists moves to a playlist named after it, the same row")
        // Dropped between two playlists, the new one goes where the line was.
        let (_, alien) = folder("new-playlists-between", files: ["Alien.1979.mkv"])
        let row = library.add(alien, to: mixed)
        library.moveToNewPlaylist(Set(row.map(\.id)), from: mixed, at: 1)
        check(library.playlists.indices.contains(1) && library.playlists[1].name == "Alien" && library.playlists[1].items.map(\.id) == row.map(\.id),
              "a row dropped between two playlists makes its playlist there: \(library.playlists.map(\.name))")
        // Files from the Finder dropped between two playlists: the same.
        let (_, dune) = folder("new-playlists-files-between", files: ["Dune.2021.mkv"])
        let known = Set(library.playlists.map(\.id))
        library.addToNewPlaylist(dune)
        library.settle(newSince: known, at: 2)
        check(library.playlists.indices.contains(2) && library.playlists[2].name == "Dune" && library.playlists[1].name == "Alien",
              "files dropped between two playlists make theirs there: \(library.playlists.map(\.name))")
        let order = library.playlists.map(\.id)
        library.settle(newSince: Set(order), at: 0)
        check(library.playlists.map(\.id) == order, "with no new playlist nothing moves")
    }

    // One add lists each file once: a folder with its own files, or reached through a link
    do {
        let (dir, _) = folder("twice")
        let show = dir.appendingPathComponent("Show", isDirectory: true)
        try! fm.createDirectory(at: show, withIntermediateDirectories: true)
        let episode = show.appendingPathComponent("Show.S01E01.mkv")
        let film = show.appendingPathComponent("Ronin.1998.mkv")
        [episode, film].forEach { fm.createFile(atPath: $0.path, contents: Data()) }
        let link = dir.appendingPathComponent("Link", isDirectory: true)
        try! fm.createSymbolicLink(at: link, withDestinationURL: show)
        let expanded = Library.expand([show, episode, film, link])
        check(expanded.map(\.lastPathComponent) == ["Ronin.1998.mkv", "Show.S01E01.mkv"],
              "a folder dropped with its own files, and again through a link, lists each file once (\(expanded.map(\.lastPathComponent)))")
        let library = Library(storeURL: dir.appendingPathComponent("library.json"))
        let pl = library.playlists[0].id
        let count = library.playlists.count
        library.add([show, episode], to: pl)
        check(library.playlists.count == count && names(library, pl) == ["Ronin.1998.mkv", "Show.S01E01.mkv"],
              "one episode dropped with the folder that holds it makes no season playlist and no second row (\(names(library, pl)))")
        // Move to Playlist into one that lists the file already
        let other = library.newPlaylist(named: "Other")
        library.add([film], to: other)
        let ids = Set(library.playlists.first { $0.id == pl }!.items.map(\.id))
        library.moveItems(ids, from: pl, to: other)
        check(names(library, other) == ["Ronin.1998.mkv", "Show.S01E01.mkv"] && names(library, pl).isEmpty,
              "moving a video into a playlist that lists it already doesn't list it twice (\(names(library, other)))")
    }

    // Dropped between two rows, files land there; playlists can be put in another order
    do {
        let (dir, files) = folder("insert", files: ["a.mkv", "b.mkv", "c.mkv", "d.mkv", "e.mkv"])
        let library = Library(storeURL: dir.appendingPathComponent("library.json"))
        let pl = library.playlists[0].id
        library.add(Array(files.prefix(3)), to: pl)
        library.add([files[3], files[4]], to: pl, at: 1)
        check(names(library, pl) == ["a.mkv", "d.mkv", "e.mkv", "b.mkv", "c.mkv"], "files dropped between rows land there, in order (\(names(library, pl)))")
        library.add([files[0], files[1]], to: pl, at: 0)
        check(names(library, pl).count == 5, "files already listed aren't added again at the drop point")
        let two = library.newPlaylist(named: "Two"), three = library.newPlaylist(named: "Three")
        library.movePlaylist(from: IndexSet(integer: 2), to: 0)
        check(library.playlists.map(\.id) == [three, pl, two], "a playlist dragged to the top of the sidebar moves there (\(library.playlists.map(\.name)))")
    }

    // Edit > Undo takes back Remove, Sort, Delete Playlist and Rename; Redo puts them back
    do {
        let (dir, files) = folder("undo", files: ["Zulu.mkv", "Alpha.mkv", "Mike.mkv"])
        let library = Library(storeURL: dir.appendingPathComponent("library.json"))
        let undo = UndoManager()
        undo.groupsByEvent = false
        library.undoManager = undo
        func step(_ change: () -> Void) { undo.beginUndoGrouping(); change(); undo.endUndoGrouping() }
        let pl = library.playlists[0].id
        step { _ = library.add(files, to: pl) }
        let added = library.playlists[0].items
        step { library.remove([added[1].id], from: pl) }
        undo.undo()
        let back = library.playlists[0].items.map(\.id) == added.map(\.id)
        undo.redo()
        check(back && names(library, pl) == ["Zulu.mkv", "Mike.mkv"] && undo.undoActionName == "Remove from Playlist",
              "undo puts a removed video back in its place, and redo removes it again (\(names(library, pl)))")
        undo.undo()
        step { library.sort(pl, by: .name) }
        let sorted = names(library, pl)
        undo.undo()
        check(sorted == ["Alpha.mkv", "Mike.mkv", "Zulu.mkv"] && names(library, pl) == ["Zulu.mkv", "Alpha.mkv", "Mike.mkv"],
              "undo after Sort gives back the order made by hand (\(names(library, pl)))")
        var other: Playlist.ID?
        step { other = library.newPlaylist(named: "Other") }
        step { library.deletePlaylist(pl) }
        let deleted = !library.playlists.contains { $0.id == pl }
        undo.undo()
        check(deleted && library.playlists.first?.id == pl && names(library, pl).count == 3 && library.playlists.contains { $0.id == other },
              "undo brings back a deleted playlist with its videos (\(library.playlists.map(\.name)))")
        step { library.setName("The Long One", for: files[0]) }
        let named = MediaItem(url: files[0]).displayName
        undo.undo()
        let unnamed = MediaItem(url: files[0]).displayName
        undo.redo()
        check(named == "The Long One" && unnamed == "Zulu" && MediaItem(url: files[0]).displayName == "The Long One",
              "undo takes back a rename and redo gives it again (\(named) -> \(unnamed))")
        step { library.setName("", for: files[0]) }
        let couldUndo = undo.canUndo
        _ = library.deleteFiles([files[2]], trash: { try fm.removeItem(at: $0) })
        check(couldUndo && !undo.canUndo, "after Delete File nothing earlier can be undone, which would list the file again")
    }

    // Locate… and Remove Missing Videos
    do {
        let (dir, files) = folder("locate", files: ["Heat.1995.mkv", "Gone.mkv", "Here.mkv"])
        let library = Library(storeURL: dir.appendingPathComponent("library.json"))
        let pl = library.playlists[0].id
        library.add(files, to: pl)
        library.updateProgress(for: files[0], position: 600, duration: 6000)
        library.setName("Heat, the long one", for: files[0])
        let moved = dir.appendingPathComponent("Films/Heat (1995).mkv")
        try! fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! fm.moveItem(at: files[0], to: moved)
        let item = library.playlists[0].items[0]
        library.relocate(item, to: moved)
        let row = library.playlists[0].items[0]
        check(row.id == item.id && row.url == moved && library.progress[moved.path]?.position == 600 && library.progress[files[0].path] == nil
              && row.displayName == "Heat, the long one" && MediaItem(url: files[0]).givenName == nil,
              "Locate… points the row at the moved file, with its place and its given name (\(row.displayName))")
        library.setName("", for: moved)
        try! fm.removeItem(at: files[1])
        library.playlists[0].items.append(MediaItem(url: URL(fileURLWithPath: "/Volumes/harness-no-such-disk/Film.mkv")))
        let removed = library.removeMissing(from: pl)
        check(removed.map(\.url.lastPathComponent) == ["Gone.mkv"] && names(library, pl) == ["Heat (1995).mkv", "Here.mkv", "Film.mkv"],
              "Remove Missing Videos removes a deleted file, not one on a disk that isn't connected (\(names(library, pl)))")
        check(Library.isOnConnectedDisk(URL(fileURLWithPath: "/Users/someone/Movies/x.mkv"))
              && !Library.isOnConnectedDisk(URL(fileURLWithPath: "/Volumes/harness-no-such-disk/x.mkv")),
              "a path on the startup disk is on a connected disk; one on a missing /Volumes disk isn't")
    }

    // MARK: Typed names and corrected titles that can't be read

    do {
        let titles = TitleOverrides.file, typed = TitleOverrides.namesFile
        let savedTitles = try? Data(contentsOf: titles), savedNames = try? Data(contentsOf: typed)
        for aside in ["title-overrides.unreadable.json", "title-names.unreadable.json"] {
            try? fm.removeItem(at: titles.deletingLastPathComponent().appendingPathComponent(aside))
        }
        try! Data("{\"broken\": ".utf8).write(to: titles)
        try! Data("[1, 2".utf8).write(to: typed)
        TitleOverrides.reload()
        let file = URL(fileURLWithPath: "/tmp/harness-titles/Unread.mkv")
        TitleOverrides.set(MediaTitle(title: "Heat", year: 1995), for: file)
        TitleOverrides.setName("Mine", for: file)
        let folder = titles.deletingLastPathComponent()
        let keptTitles = try? String(contentsOf: folder.appendingPathComponent("title-overrides.unreadable.json"), encoding: .utf8)
        let keptNames = try? String(contentsOf: folder.appendingPathComponent("title-names.unreadable.json"), encoding: .utf8)
        TitleOverrides.reload()
        check(keptTitles == "{\"broken\": " && keptNames == "[1, 2" && TitleOverrides.title(for: file)?.title == "Heat" && TitleOverrides.name(for: file) == "Mine",
              "corrected titles and typed names that can't be read are kept aside, not written over by the next one")
        for (url, data) in [(titles, savedTitles), (typed, savedNames)] {
            if let data { try? data.write(to: url) } else { try? fm.removeItem(at: url) }
        }
        for aside in ["title-overrides.unreadable.json", "title-names.unreadable.json"] { try? fm.removeItem(at: folder.appendingPathComponent(aside)) }
        TitleOverrides.reload()
    }

    // MARK: The watched list

    do {
        let (dir, _) = folder("watched")
        let t0 = Date(timeIntervalSince1970: 1_795_000_000)
        let a = WatchedList.Entry(title: "01", filename: "01.mkv", played: t0, path: "/Shows/One/01.mkv")
        let b = WatchedList.Entry(title: "01", filename: "01.mkv", played: t0 + 60, path: "/Shows/Two/01.mkv")
        let c = WatchedList.Entry(title: "01", filename: "01.mkv", played: t0 + 120, path: "/Shows/Two/01.mkv")
        let added = [a, b, c].map { try! WatchedList.add($0, in: dir) }
        let read = WatchedList.entries(in: dir)
        check(added == [true, true, false] && read == [a, b] && !WatchedList.csv(read).contains("/Shows/"),
              "watched list: two files of one name are two viewings, the same file again isn't; the folder stays out of the spreadsheet (\(added))")
        let json = WatchedList.jsonURL(in: dir)
        let before = try! Data(contentsOf: json)
        try! fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: json.path)
        let refused = (try? WatchedList.add(.init(title: "Heat (1995)", filename: "Heat.1995.mkv", played: t0 + 9000), in: dir)) == nil
        let threw = (try? WatchedList.readEntries(in: dir)) == nil
        try! fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: json.path)
        check(refused && threw && (try? Data(contentsOf: json)) == before,
              "watched list: a list that can't be opened is left as it is, not replaced by one entry")
    }

    // MARK: Names made from file names

    // Shows named with a number get their season playlist; the rows read as before
    do {
        let pairs = [["24.S01E01", "24.S01E02"], ["24.S01E01.1080p.BluRay.x264-GRP", "24.S01E02.1080p.BluRay.x264-GRP"],
                     ["1883.S01E01.mkv", "1883.S01E02.mkv"], ["9-1-1.S02E03", "9-1-1.S02E04"], ["90210.1x01", "90210.1x02"], ["V.S01E01", "V.S01E02"]]
        let titles = pairs.map { SeriesName.group($0).series.map(\.title) }
        check(titles == [["24 S1"], ["24 S1"], ["1883 S1"], ["9-1-1 S2"], ["90210 S1"], ["V S1"]],
              "series: a show named with a number or one letter gets its season playlist (\(titles))")
        check(MediaTitle.parse(fileName: "24.S01E01.1080p.BluRay.x264-GRP").displayName == "24 S1 E1"
              && SeriesName.title(fromFileName: "Lecture 01") == nil && SeriesName.title(fromFileName: "Part 2") == nil,
              "series: before a looser marker a bare number still isn't a show")
    }

    // File names that came out wrong
    let named: [(String, String)] = [
        ("[REC] (2007)", "[REC] (2007)"),
        ("[REC].2007.1080p.BluRay.x264", "[REC] (2007)"),
        ("[REC]", "[REC]"),
        ("(500) Days of Summer (2009)", "(500) Days of Summer (2009)"),
        ("(500).Days.of.Summer.2009.1080p.BluRay", "(500) Days of Summer (2009)"),
        ("[Group] Some Show - 03 [1080p]", "Some Show E3"),
        ("IMG_2019", "IMG 2019"),
        ("DSC_2015", "DSC 2015"),
        ("MVI_2020", "MVI 2020"),
        ("DJI_2024", "DJI 2024"),
        ("3rd.rock.from.the.sun.s01e01", "3rd Rock From The Sun S1 E1"),
        ("se7en.1995.720p", "Se7en (1995)"),
        ("ice.age.2002", "Ice Age (2002)"),
        ("spider-man.2002", "Spider-Man (2002)"),
        // An episode's show keeps the year or country it was named with
        ("Doctor.Who.2005.S01E01.mkv", "Doctor Who 2005 S1 E1"),
        ("The.Office.US.S01E01", "The Office US S1 E1"),
        ("1923.S01E01", "1923 S1 E1"),
        // Fan releases and a bare E03 are episodes; numbers that aren't stay in the name
        ("Some.Show.E03.720p", "Some Show E3"),
        ("Concert - 2019", "Concert (2019)"),
        ("Party - 12.05.2023", "Party - 12.05.2023"),
        ("Rocky - 2", "Rocky - 2"),
    ]
    for (file, shown) in named {
        let got = MediaTitle.parse(fileName: file).displayName
        check(got == shown, "display name: \(file) -> \(got)")
    }
    check(MediaTitle.isDeviceRecording(fileName: "IMG_2019") && MediaTitle.isDeviceRecording(fileName: "PXL_20240102_103015123")
          && MediaTitle.isDeviceRecording(fileName: "GOPR0042") && MediaTitle.isDeviceRecording(fileName: "Screen Recording 2024-01-02 at 10.30.15 AM")
          && !MediaTitle.isDeviceRecording(fileName: "Movie 43") && !MediaTitle.isDeviceRecording(fileName: "Video Days 2019")
          && !MediaTitle.isDeviceRecording(fileName: "Heat.1995.1080p"), "camera, phone and screen recording names are told from films")

    // An episode's year and country are what the show is looked up by
    let who = MediaTitle.parse(fileName: "Doctor.Who.2005.S01E01.mkv")
    let shogun = MediaTitle.parse(fileName: "Shogun.2024.S01E01")
    let flash = MediaTitle.parse(fileName: "The.Flash.2014.S01E01.720p")
    let theOffice = MediaTitle.parse(fileName: "The.Office.US.S01E01")
    let usBand = MediaTitle.parse(fileName: "This.Is.Us.S01E01")
    check(who.title == "Doctor Who" && who.year == 2005 && who.season == 1 && who.episode == 1 && who.searchQuery == "Doctor Who 2005"
          && shogun.title == "Shogun" && shogun.year == 2024 && flash.title == "The Flash" && flash.year == 2014
          && theOffice.title == "The Office" && theOffice.country == "US" && theOffice.year == nil
          && usBand.title == "This Is Us" && usBand.country == nil && who.tvLines(lookedUp: true).title == "Doctor Who 2005",
          "an episode: a year or country after the show's name is taken out for the lookup (\(who.title) \(who.year ?? 0), \(theOffice.title) \(theOffice.country ?? "-"))")
    check(who.asWritten == MediaTitle(title: "Doctor Who 2005", season: 1, episode: 1) && MediaTitle.parse(fileName: "Heat.1995").asWritten == nil,
          "an episode whose show's name was split can be asked for as written")

    // Titles are compared by whole words
    let heatTitle = MediaTitle(title: "Heat", year: 1995)
    check(TitleMatch.score(candidate: "Cheat Sheet", year: nil, wanted: MediaTitle(title: "Heat")) == 0
          && TitleMatch.score(candidate: "Mother Father Son", year: nil, wanted: MediaTitle(title: "Her")) == 0
          && TitleMatch.score(candidate: "In the Heat of the Night", year: 1995, wanted: heatTitle) == 3
          && TitleMatch.score(candidate: "Heat Wave", year: nil, wanted: heatTitle) == 1,
          "title matching: whole words only (Cheat Sheet isn't Heat, Mother Father Son isn't Her)")

    // TVmaze's search: the year picks among shows of one name, the country among remakes
    func tvShow(_ id: Int, _ name: String, _ premiered: String, _ country: String) -> String {
        #"{"score":0.9,"show":{"id":\#(id),"name":"\#(name)","premiered":"\#(premiered)","network":{"name":"N","country":{"code":"\#(country)"}}}}"#
    }
    let whoSearch = Data(("[" + [tvShow(766, "Doctor Who", "1963-11-23", "GB"), tvShow(210, "Doctor Who", "2005-03-26", "GB"),
                                 tvShow(70880, "Doctor Who", "2023-11-25", "GB"), tvShow(5, "Doctor Who Confidential", "2005-03-26", "GB")].joined(separator: ",") + "]").utf8)
    let officeSearch = Data(("[" + [tvShow(526, "The Office", "2005-03-24", "US"), tvShow(9, "The Office", "2001-07-09", "GB")].joined(separator: ",") + "]").utf8)
    let picked = [TVmaze.pickShow(whoSearch, wanted: who)?.1, TVmaze.pickShow(whoSearch, wanted: MediaTitle(title: "Doctor Who", season: 1, episode: 1))?.1,
                  TVmaze.pickShow(officeSearch, wanted: MediaTitle.parse(fileName: "The.Office.UK.S01E01"))?.1, TVmaze.pickShow(officeSearch, wanted: theOffice)?.1,
                  TVmaze.pickShow(whoSearch, wanted: MediaTitle(title: "Doctor Who", year: 1990, season: 1, episode: 1))?.1,
                  TVmaze.pickShow(whoSearch, wanted: MediaTitle(title: "Doctor", season: 1, episode: 1), exactOnly: true)?.1]
    check(picked == [210, 766, 9, 526, nil, nil],
          "TVmaze: the 2005 Doctor Who for Doctor.Who.2005, the first listed with no year, the British Office for .UK., none for a year that fits no show (\(picked))")
    check(TVmaze.searchURL("Doctor Who")?.absoluteString == "https://api.tvmaze.com/search/shows?q=Doctor%20Who", "TVmaze: shows are searched for, not picked one by one")

    // OMDb: the year and country of an episode's show are held against its answer
    let omdbSeries = Data(#"{"Title":"Doctor Who","Year":"1963–1989","Country":"United Kingdom","Type":"series","Response":"True"}"#.utf8)
    let omdbOffice = Data(#"{"Title":"The Office","Year":"2005–2013","Country":"United States","Type":"series","Response":"True"}"#.utf8)
    check(OMDbClient.parse(omdbSeries, wanted: who) == nil && OMDbClient.parse(omdbSeries, wanted: MediaTitle(title: "Doctor Who", season: 1, episode: 1)) != nil
          && OMDbClient.parse(omdbOffice, wanted: theOffice) != nil && OMDbClient.parse(omdbOffice, wanted: MediaTitle.parse(fileName: "The.Office.UK.S01E01")) == nil,
          "OMDb: a show from another year or country than the file names isn't taken")

    // OMDb's own reasons, kept for Settings with the key they were about
    check(OMDbClient.error(in: Data(#"{"Response":"False","Error":"Invalid API key!"}"#.utf8)) == "Invalid API key!"
          && OMDbClient.error(in: Data(#"{"Title":"Heat","Response":"True"}"#.utf8)) == nil
          && OMDbClient.isNotFound("Series or episode not found!") && !OMDbClient.isNotFound("Request limit reached!")
          && OMDbClient.problem(status: 401, said: "Invalid API key!") == "OMDb didn't accept the key."
          && OMDbClient.problem(status: 401, said: "Request limit reached!") == "The key's requests for today are used up."
          && OMDbClient.problem(status: 503, said: nil) == "OMDb answered with error 503.", "OMDb: what went wrong is said plainly")
    do {
        let savedKey = Prefs.defaults.string(forKey: Prefs.omdbKey)
        Prefs.defaults.set("harness-key-1", forKey: Prefs.omdbKey)
        OMDbClient.noteProblem("OMDb didn't accept the key.")
        let shown = OMDbClient.problem
        Prefs.defaults.set("harness-key-2", forKey: Prefs.omdbKey)
        let otherKey = OMDbClient.problem
        Prefs.defaults.set("harness-key-1", forKey: Prefs.omdbKey)
        OMDbClient.noteProblem(nil)
        check(shown == "OMDb didn't accept the key." && otherKey == nil && OMDbClient.problem == nil,
              "OMDb: the last problem is shown for the key it was about, not for a new key, and goes with the next answer")
        if let savedKey { Prefs.defaults.set(savedKey, forKey: Prefs.omdbKey) } else { Prefs.defaults.removeObject(forKey: Prefs.omdbKey) }
    }

    // A Wikidata running time too large for a number is left out rather than stopping the app
    let absurd = #"{"entities":{"Q1":{"claims":{"P2047":[{"mainsnak":{"datavalue":{"value":{"amount":"+99999999999999999999999","unit":"http://www.wikidata.org/entity/Q7727"}}}}]}}}}"#
    let sane = #"{"entities":{"Q1":{"claims":{"P2047":[{"mainsnak":{"datavalue":{"value":{"amount":"+7200","unit":"http://www.wikidata.org/entity/Q11574"}}}}]}}}}"#
    check(Wikidata.parseEntity(Data(absurd.utf8), qid: "Q1").durationMinutes == nil && Wikidata.parseEntity(Data(sane.utf8), qid: "Q1").durationMinutes == 120,
          "Wikidata: an absurd running time is left out; seconds are read as minutes")

    // Sound files and a camera's or the screen recorder's videos aren't looked up by themselves
    do {
        let (_, files) = folder("lookup", files: ["Yesterday.mp3", "IMG_2019.MOV", "Screen Recording 2024-01-02 at 10.30.15.mov", "Heat.1995.mkv"])
        let by = files.map(MetadataLookup.looksUpByItself)
        TitleOverrides.set(MediaTitle(title: "Yesterday", year: 2019), for: files[0])
        let corrected = MetadataLookup.looksUpByItself(files[0])
        TitleOverrides.set(nil, for: files[0])
        let none = try! await_ { await MetadataLookup.shared.details(for: files[1]) }.get()
        let cached = try! await_ { await MetadataLookup.shared.cached(for: files[2]) }.get()
        check(by == [false, false, false, true] && corrected && none == nil && cached == nil,
              "online details: a sound file, a camera's video and a screen recording aren't looked up by themselves; after Search by Title… they are (\(by))")
    }
}
