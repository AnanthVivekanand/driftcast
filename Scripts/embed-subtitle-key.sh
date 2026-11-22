#!/bin/sh
# Puts Driftcast's OpenSubtitles API key into the app being built, without the key ever being
# in the repository. Run by the target's "Bundle ffmpeg and licenses" build phase.
#
# The key is read from the login keychain (item "driftcast-opensubtitles"; store it with
# Scripts/set-subtitle-key.sh) or from $DRIFTCAST_OPENSUBTITLES_KEY. It is written to
# Contents/Resources/OpenSubtitles.key as 32 random bytes followed by the key XORed with them,
# so it doesn't show up as plain text in the app. That only hides it from a casual look: the app
# has to send the real key, so anyone determined can recover it from the app.
#
# With no key (a fresh clone of the repository, CI, or DRIFTCAST_NO_SUBTITLE_KEY=1), nothing is
# written and that build's online subtitle search says it isn't set up.
set -e
OUT="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/OpenSubtitles.key"
rm -f "$OUT"
KEY=""
if [ -z "$DRIFTCAST_NO_SUBTITLE_KEY" ]; then
  KEY="${DRIFTCAST_OPENSUBTITLES_KEY:-$(security find-generic-password -s driftcast-opensubtitles -w 2>/dev/null || true)}"
fi
if [ -z "$KEY" ]; then
  echo "note: no OpenSubtitles key in the keychain (Scripts/set-subtitle-key.sh); this build's online subtitle search won't work."
  exit 0
fi
mkdir -p "$(dirname "$OUT")"
# The key goes to perl through the environment, so it is never on a command line.
OSKEY="$KEY" /usr/bin/perl -e '
  my $k = $ENV{OSKEY}; $k =~ s/^\s+|\s+$//g;
  open(my $r, "<", "/dev/urandom") or die; read($r, my $m, 32) == 32 or die;
  my $o = ""; for my $i (0 .. length($k) - 1) { $o .= chr(ord(substr($k, $i, 1)) ^ ord(substr($m, $i % 32, 1))) }
  binmode STDOUT; print $m . $o;' > "$OUT"
echo "OpenSubtitles key embedded."
