#!/bin/bash
set -e

# Date-based version: MAJOR.MINOR.PATCH = YEAR . (MM*100+DD) . BUILD
#
#   2026.611.0   -> first build of 2026-06-11
#   2026.611.1   -> second build the same day
#   2026.612.0   -> first build of 2026-06-12
#
# MINOR encodes the month+day as an integer (no leading zeros, so it stays a valid
# SemVer identifier and a valid Docker tag), and PATCH is the build number within the
# day - so we can ship more than one release in a single day. Bumping on a day that
# already has a release increments PATCH; a new day resets it to 0.

YEAR=$(date +"%Y")
MONTH=$(date +"%-m")
DAY=$(date +"%-d")
MINOR=$((MONTH * 100 + DAY))

CURRENT=$(grep "version: " mix.exs | cut -d '"' -f2)
CUR_MAJOR=$(echo "$CURRENT" | cut -d. -f1)
CUR_MINOR=$(echo "$CURRENT" | cut -d. -f2)
CUR_PATCH=$(echo "$CURRENT" | cut -d. -f3)

if [ "$CUR_MAJOR" = "$YEAR" ] && [ "$CUR_MINOR" = "$MINOR" ]; then
  BUILD=$((CUR_PATCH + 1))
else
  BUILD=0
fi

NEW="$YEAR.$MINOR.$BUILD"

echo "Bumping version from $CURRENT to $NEW"
# Replace the version in mix.exs with the new version
sed -i "s/version: \"$CURRENT\"/version: \"$NEW\"/g" mix.exs

# Run checks to ensure it's a valid mix.exs file
mix check

echo "Version bumped successfully to $NEW"
