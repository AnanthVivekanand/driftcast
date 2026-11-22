#!/bin/sh
# Stores Driftcast's OpenSubtitles API key in the login keychain, where builds read it
# (Scripts/embed-subtitle-key.sh). The key never goes into the repository.
#   Scripts/set-subtitle-key.sh          asks for the key (typing isn't shown)
#   Scripts/set-subtitle-key.sh --remove removes it
set -e
if [ "$1" = "--remove" ]; then
  security delete-generic-password -s driftcast-opensubtitles >/dev/null && echo "Removed."
  exit 0
fi
# security asks for the key itself (typing isn't shown), so it is never on a command line.
# -U replaces an existing key.
echo "Paste the OpenSubtitles API key when asked for the password data."
security add-generic-password -U -s driftcast-opensubtitles -a driftcast -l "Driftcast OpenSubtitles API key" -w
echo "Stored. The next build of Driftcast includes it."
