---
title: Free Mac App to Cast MKV and Any Video to Chromecast and Apple TV
description: Driftcast plays MKV, AVI and nearly any video from your Mac on Chromecast, Apple TV and AirPlay 2 TVs. Free and open source; an alternative to Airflow, Beamer, Elmedia Player, JustStream, Infuse and Plex.
---

<p align="center"><img src="images/icon-360.png" width="180" height="180" alt="The Driftcast app icon"></p>

<p align="center"><a href="https://github.com/leechsoftware/driftcast/releases/latest"><img alt="Download the latest version of Driftcast" src="https://img.shields.io/github/v/release/leechsoftware/driftcast?style=for-the-badge&label=Download&color=F0468F&logo=apple&logoColor=white" height="42"></a><br><small>Free disk image for macOS 13 or later, Apple silicon and Intel · <a href="https://github.com/leechsoftware/driftcast/releases">All releases</a></small></p>

**Nearly any video on your Mac, on the biggest screen in the house.** Chromecast, Apple TV and AirPlay 2 TVs, with no waiting and no conversion it doesn't need. Driftcast streams MKV, AVI, WMV, TS and nearly any other video file, converting only what the device can't play.

Driftcast is a free, open-source Mac app from Leech Software. It is the free alternative to Airflow, Beamer, Elmedia Player, JustStream, Infuse and Plex for playing the video files on your Mac on the TV.

<p><a href="https://github.com/leechsoftware/driftcast/releases/latest"><strong>Download the latest version</strong></a> · <a href="https://github.com/leechsoftware/driftcast">Source code on GitHub</a> · <a href="https://github.com/leechsoftware/driftcast/blob/main/docs/DESCRIPTION.md">Everything it does, in detail</a> · <a href="https://github.com/leechsoftware/driftcast/blob/main/PRIVACY.md">Privacy</a></p>

macOS 13 Ventura or later, Apple silicon and Intel. Free, under the GNU GPL v3. No account, no trial, no ads, no tracking.

<video controls preload="metadata" poster="images/steps/6-playing-with-subtitles.png" width="100%" src="media/driftcast-demo.mp4">Your browser can't play this video. <a href="media/driftcast-demo.mp4">Download it</a>.</video>

<p><small>The demo, with narration: drop in videos, see a poster and details, add subtitles found online, play, and send it to a TV with AirPlay.</small></p>

## Screenshots

<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px">
<figure style="margin:0"><a href="images/steps/1-drop-in-movies-and-shows.png"><img src="images/steps/1-drop-in-movies-and-shows.png" alt="Three video files dragged from the desktop into the Driftcast window" loading="lazy" style="width:100%;border-radius:6px"></a><figcaption><small>1. Drop in movies and shows</small></figcaption></figure>
<figure style="margin:0"><a href="images/steps/2-movie-poster-and-details.png"><img src="images/steps/2-movie-poster-and-details.png" alt="The details panel showing The Matrix poster, year, genres and ratings" loading="lazy" style="width:100%;border-radius:6px"></a><figcaption><small>2. A movie's poster and details</small></figcaption></figure>
<figure style="margin:0"><a href="images/steps/3-subtitles-found-online.png"><img src="images/steps/3-subtitles-found-online.png" alt="A bubble offering English subtitles found online for a TV episode with none in the file" loading="lazy" style="width:100%;border-radius:6px"></a><figcaption><small>3. Subtitles found online</small></figcaption></figure>
<figure style="margin:0"><a href="images/steps/4-subtitles-added.png"><img src="images/steps/4-subtitles-added.png" alt="The details panel reading Closed Captions: English after the subtitles were added" loading="lazy" style="width:100%;border-radius:6px"></a><figcaption><small>4. Subtitles added</small></figcaption></figure>
<figure style="margin:0"><a href="images/steps/5-title-card.png"><img src="images/steps/5-title-card.png" alt="The video window showing a title card with the show's poster, episode and air date" loading="lazy" style="width:100%;border-radius:6px"></a><figcaption><small>5. A title card as it starts</small></figcaption></figure>
<figure style="margin:0"><a href="images/steps/6-playing-with-subtitles.png"><img src="images/steps/6-playing-with-subtitles.png" alt="The episode playing in the video window with English subtitles" loading="lazy" style="width:100%;border-radius:6px"></a><figcaption><small>6. Playing, with subtitles</small></figcaption></figure>
<figure style="margin:0"><a href="images/steps/7-play-on-menu.png"><img src="images/steps/7-play-on-menu.png" alt="The Play on menu listing This Mac, Chromecast and AirPlay" loading="lazy" style="width:100%;border-radius:6px"></a><figcaption><small>7. Choose where to play</small></figcaption></figure>
<figure style="margin:0"><a href="images/steps/8-airplay-device-list.png"><img src="images/steps/8-airplay-device-list.png" alt="The AirPlay list with a TV being ticked" loading="lazy" style="width:100%;border-radius:6px"></a><figcaption><small>8. Pick your TV</small></figcaption></figure>
<figure style="margin:0"><a href="images/steps/9-playing-on-the-tv.png"><img src="images/steps/9-playing-on-the-tv.png" alt="The small video window reading Connected to AirPlay TV while the episode plays on the TV" loading="lazy" style="width:100%;border-radius:6px"></a><figcaption><small>9. Playing on the TV</small></figcaption></figure>
</div>

<small>The Sopranos, The Matrix and Breaking Bad, with their posters and artwork, belong to their owners and are shown only to demonstrate the app.</small>

## Why Driftcast

- **Plays nearly anything:** MKV, MP4, MOV, AVI, WMV, WebM, TS, M2TS, VOB, MPEG, FLV, DivX, RMVB, MXF and more. H.264, HEVC, AV1, VP9, VP8, MPEG-2, VC-1, ProRes, HDR10, HLG and Dolby Vision. Dolby Atmos, E-AC-3, AC-3, DTS-HD, TrueHD, FLAC, ALAC, AAC and Opus.
- **Converts only what it must:** a file the device can play is sent untouched. When only the container is wrong, the streams are repackaged with no quality loss. Only a stream the device can't decode is converted, while you watch.
- **Runs on the GPU:** decoding, scaling, HDR tone mapping and H.264 encoding stay in VideoToolbox, about a thirtieth of the CPU time of a software conversion.
- **Real seeking:** the device receives the complete playlist before conversion starts, so it shows the true duration and the TV remote can skip and scrub.
- **Every Chromecast:** 1st to 3rd generation, Chromecast HD, Ultra, Chromecast with Google TV, Google TV Streamer, Nest Hub and TVs with Chromecast built in, each getting exactly what it can play. Google speakers get the sound.
- **Apple TV and AirPlay 2 TVs** from Samsung, LG, Sony, Roku, Vizio, Hisense and others, with HEVC, HDR and Dolby audio passed through.
- **Subtitles done properly:** text tracks in any encoding, subtitle files found beside the video, Blu-ray PGS and DVD VobSub read into text on your Mac, and a built-in OpenSubtitles search that downloads and turns a subtitle on in one step.
- **Film and show details:** poster, plot, cast, director, genres, age rating and IMDb, Rotten Tomatoes and Metacritic scores, with no account.
- **A title card** with the poster before the film starts, playlists, resume, watched marks, preview frames on the timeline, media keys, and every control in a menu.
- **Updates itself,** checking that each new version is signed by Leech Software before it is installed.

## Get it

1. [Download the latest release](https://github.com/leechsoftware/driftcast/releases/latest) and open the disk image.
2. Drag Driftcast to your Applications folder.
3. Open it, drop a video on the window, and pick your TV.

Release builds are signed with a Developer ID and notarized by Apple. The source code, build scripts and automated checks are all on [GitHub](https://github.com/leechsoftware/driftcast); changes are welcome.

## Guides

- [How to cast MKV files to Chromecast from a Mac]({{ '/how-to-cast-mkv-to-chromecast-from-mac/' | relative_url }})
- [How to play MKV files on Apple TV from a Mac]({{ '/play-mkv-on-apple-tv-from-mac/' | relative_url }})
- [How to send any video from a Mac to a Samsung or LG TV]({{ '/airplay-video-from-mac-to-samsung-lg-tv/' | relative_url }})
- [How to get subtitles on Chromecast from a Mac]({{ '/chromecast-subtitles-from-mac/' | relative_url }})
- [How to play DTS audio on Chromecast from a Mac]({{ '/dts-audio-chromecast-mac/' | relative_url }})
- [How to cast 4K HDR video from a Mac]({{ '/cast-4k-hdr-video-from-mac/' | relative_url }})
- [A free Airflow alternative for Mac]({{ '/free-airflow-alternative-for-mac/' | relative_url }})

## Supported macOS versions and Macs

| macOS | Apple silicon | Intel |
|---|:-:|:-:|
| macOS 26 Tahoe | ✓ | ✓ |
| macOS 15 Sequoia | ✓ | ✓ |
| macOS 14 Sonoma | ✓ | ✓ |
| macOS 13 Ventura | ✓ | ✓ |

One universal app, with FFmpeg already inside it. Nothing else to install.

---

Copyright © 2026 [Leech Software, Inc.](https://leechsoftware.com) Driftcast is free software under the GNU General Public License v3 or later. Chromecast, Google TV, Apple TV, AirPlay, macOS, Dolby and DTS are trademarks of their owners; Driftcast is not affiliated with or endorsed by any of them.
