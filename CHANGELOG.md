# What's changed in Driftcast

What is new and what was fixed in each version, newest first. Downloads and the notes for
earlier versions are on the [releases page](https://github.com/leechsoftware/driftcast/releases).

## 1.1.2 (20 November 2026)

### New

- **Open…:** there was no command called Open, and nothing in the window that looked like
  opening a file. Videos came in through Add Videos… (⌘O) and a + button, and those only
  listed a video: it still had to be found in the list and played. File > Open… (⌘O) and a
  folder button beside the playlist's name now choose a video from your Mac, add it to the
  playlist and play it, as opening a video from the Finder always has. Several videos or a
  folder are added and the first one plays. A video that is already listed plays from its row
  and isn't listed twice.
- **Add Videos…** stays, for lining videos up without interrupting what is playing: the +
  button beside the folder, and ⇧⌘O in the File menu (it was ⌘O).
- **Select All:** ⌘A selected the videos only after a click in the list; after a click in the
  sidebar it did nothing. It now selects every video in the playlist wherever the keyboard is
  in the main window, and Select All is in the right-click menus. While you are typing a name
  it still selects the text.
- **Right-click in the list of playlists:** New Playlist and Delete Playlist now come first,
  above Rename and Add Videos…, and the menu opens wherever on the row you click. A
  right-click in the empty space under the playlists offers New Playlist. Before, the menu
  had no New Playlist, and nothing came up in the empty space.

### Changed

- **A playlist for each season:** dropping or opening episodes of a show put them all in one
  playlist named after the show, every season together. Each season now gets its own:
  "Sopranos S1", "Sopranos S2", in episode order. One episode added on its own stays where
  you drop it, unless its season already has a playlist, which it joins. A playlist you
  already have that is named after the show and holds one season takes that season's name
  the next time you add to the show; one that mixes seasons is left as it is.
- **The list of videos you watch is out of sight:** 1.1.1 kept it as two files in your Movies
  folder, where anyone looking through the folder could read what was watched. It is now kept
  inside Driftcast's own data, and Export Watched Videos… (the File menu, or the Export…
  button in Settings > General) is how you get it, as a spreadsheet. The two files in Movies
  are taken in and removed the first time this version opens, and nothing in them is lost.
  The list is hidden, not locked: someone who knows where an app keeps its data can open it.
- **"I don't care about subtitles"** is now the first setting in Settings > Subtitles, and it
  means what it says. It used to hide the notices only: with "Always turn on closed captions"
  ticked as well, captions still came on. Now captions never come on by themselves and none
  are searched for as a video starts, and the other subtitle settings are grayed out, titles
  included, until you turn it off. They keep their values, and the Subtitles menu still works
  for a single video. It is still off unless you turn it on.
- **No caption bar for a video without captions:** the bar under the video said "No closed
  captions in this video" and took room from the picture to say it. It now shows only when
  the video has captions to choose from. Find Subtitles Online… is still in the Subtitles
  menu and behind the playback bar's button.
- **An episode's name on its own line:** the details panel wrote "Season 4, Episode 7:
  Watching Too Much Television" as one line, which broke in the middle of the name. The name
  is now under the season and episode.

### Fixed

- **The caption bar under the video was cut off:** the video window could be made, or come
  back, short enough that the bar saying which captions a video has lost its lower half. The
  window's smallest size didn't count its title bar. It does now, and a window that is too
  short grows to show the whole bar. The same miscount brought the window back shorter by the
  title bar's height each time casting ended.
- **A folder opened twice from the Finder:** when the folder was reached through a link, the
  second time played nothing. It plays the folder's first video from the list.

## 1.1.1 (19 November 2026)

### New

- **A list of the videos you watch:** each video that starts playing is added to "Videos I
  have watched on Driftcast" in your Movies folder: the file's name, its cleaned name, and the
  date and time, newest first. The same list sits under it as a JSON file (`filename`,
  `title`, `played`) for anything that wants to work with it. Starting the same video again
  within 30 minutes counts as the same viewing. Turn it off in Settings > General. The list is
  in the Movies folder because an app can write there without asking; Documents, Desktop and
  Downloads each put up a permission question first.
- **Export Watched Videos…** in the File menu saves that list as a CSV spreadsheet (File,
  Title, Played) wherever you choose.
- **An error log:** when something fails, a line goes to `~/Library/Logs/Driftcast/Errors.log`
  with the time, the version, what was being done, the file, the system's reason and its
  error numbers. An alert is gone once you close it; the log is what to read, or attach to a
  report, afterwards. Help > Show Error Log shows the file in the Finder. Logged: a video
  that won't start or stops with an error, an AirPlay TV that connects but never asks for the
  video, a file that can't be moved to the Trash, a failed subtitle search or download, a
  failed update, a failed Chromecast search, a poster card that couldn't be made, and a
  watched list that can't be written.

### Fixed: deleting a file

Right-click > Delete File… could end in "Some files couldn't be deleted" when nothing was
wrong.

- **A file listed twice:** with both rows selected, the file went to the Trash for the first
  row and the second then failed, because the file was no longer there. A file is now moved
  once however many rows name it.
- **A file already deleted in the Finder:** there was nothing left to move, so the command
  failed and the row stayed in the playlist. Such a file now just leaves the playlists. A file
  on a disk that isn't connected is different: it stays listed, and the alert says why.
- Every file that can't be moved is written to the error log with the system's reason.

### Fixed: names

Version 1.1 began showing a cleaned name in place of the file name. These are the names it
got wrong.

- **Everyday words read as release tags:** words such as Extended, Proper, Limited, Internal
  and Dolby mark a release ("Heat.1995.EXTENDED.1080p"), and the name was cut at the first
  one. "Our Extended Family Christmas 2023" showed as "Our (2023)" and "A Proper Wedding" as
  "A". Such a word now ends the name only when nothing but tags follows it, so those keep
  their names and "Some.Film.Extended.Cut.1080p" is still "Some Film".
- **A year in square brackets was lost:** "Heat [1995]" showed as "Heat" with no year, because
  bracketed tags at the end of a name were removed before the year was read. The online lookup
  then searched without a year and could bring back another film of the same name.
- **Numbers before a year were read as a date:** "Fahrenheit.9.11.2004.DVDRip" and
  "Die.Hard.4.0.2007.1080p" lost their year, because two short numbers before a year looked
  like a day and a month. They count as a date now only when they can be one (4.0 can't) and
  no release tags follow the year. "Party 12.05.2023" is still a date.
- **Two years in a row:** "Wonder.Woman.1984.2020.1080p" showed as "Wonder Woman (1984)". The
  second year is when the film came out; it now reads "Wonder Woman 1984 (2020)".
- **A year followed by the name of a cut:** "Movie 2010 Directors Cut" kept the year in its
  name and was looked up without one. It is now "Movie (2010)". A cut's own word (cut,
  edition, version) has to be there, so "Project 2023 Final" keeps its name.
- **A film with "Episode" in its name:** "Star.Wars.Episode.4.A.New.Hope.1977.1080p" showed
  as "Star Wars E4", an episode of a show, with no year. "Episode 4" with no season, then more
  of the name, then a year is now a film: "Star Wars Episode 4 A New Hope (1977)".
- **A hyphenated title with a number:** "Spider-Man-2" showed as "Spider Man 2". It now reads
  "Spider-Man 2".
- **A title you corrected was shown in one place only:** after Search by Title… in the details
  panel, the corrected name appeared there but the list, the window, the Now Playing bar, the
  TV's panel and the watched list still showed the name made from the file. They all use the
  corrected title now, and the list updates at once.

### Fixed: subtitles

- **MATCH on the wrong subtitle:** a result was tagged MATCH when it came from the same release
  group and source as your file, without checking that it was for the same film. A subtitle
  for "Aliens" from the group that released your "Alien", for the extended cut when you have
  the cinema one, for a sequel, or for a whole season's pack could be tagged, listed first,
  and downloaded by the automatic search, and then run out of sync. MATCH now also needs the
  same title, the same cut and the same episode.
- **Codec names read as the release group:** in a name ending "WEB.H-264" the group was taken
  to be "264", and in "DTS-ES" to be "es", so two unrelated releases could look like one
  group's work. A group now needs letters, can't be a known tag ending, and is only read from
  a name that has release tags; "Spider-Man" on its own has no group "man". A language with a
  region after the group ("-GRP.pt-BR") is skipped like a plain language code.
- **The size slider out of place after AirPlay:** the size controls are hidden while
  AirPlaying. When AirPlay ended the slider could come back below its usual place in the
  Subtitles menu. It is put back under Smaller Subtitles.
- **A double flicker when changing the size quickly:** two quick changes could each redraw the
  subtitle on screen. Only the last one does.

### Fixed: playback and casting

- **Casting to a speaker blanked the window:** a speaker is sent the sound alone, and the
  casting window's silent copy of that stream has no picture, so the poster was replaced by a
  gray veil over black for the whole cast. The poster now stays.
- **"Finished" came late, or early:** the credits were taken from the last chapter with
  "credit" in its name. With "End Credits" followed by a "Post-Credits Scene" chapter the
  later one was used, so stopping as the credits began left the film unfinished with minutes
  to go. The first credits chapter in the second half now counts. "Credit" inside another
  word or name ("The Credit Crunch", "Accreditation") no longer counts as the credits.
- **A video window in the Dock counted as closed:** with the window minimized, pressing play
  brought it back out, and AirPlay ending paused the video as if nobody could see it. A
  minimized window is an open one now.
- **The year missing on the TV's panel:** a film found online drops its year from the TV's
  pause and seek panel because the poster card has just shown it. It was dropped with the
  card turned off too. The year stays when there is no card.
- **The casting window's silent copy:** it could present itself to macOS as what is playing,
  and so reach Now Playing and the media keys. It could also go on following a stream that
  had failed to load, and take a late answer about a replaced stream for the current one.
  All three are fixed.

### Known limits

- The poster card can't be made for a film whose sound is Dolby Digital Plus in 6.1 or 7.1
  and is passed through unchanged: ffmpeg can't write silent sound in that layout. The film
  plays without the card, and the error log says so. 7.1 in AAC, FLAC, ALAC and Opus is fine.

### Also

- The privacy policy lists the watched list and the error log among what stays on your Mac.
- British spellings in the README and code comments changed to American.
