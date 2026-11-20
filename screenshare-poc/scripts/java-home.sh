#!/bin/bash
# Prints a JDK that Gradle 8.14 can run on (17–24): an installed one, else Android Studio's bundled JBR.
# Newest first; java_home exits non-zero when that version is not installed.
for version in 24 23 22 21 17; do
  if home=$(/usr/libexec/java_home -v "$version" 2>/dev/null) && [ -n "$home" ]; then
    echo "$home"; exit 0
  fi
done
# Fallback: the JetBrains Runtime bundled with Android Studio is a full JDK.
for app in "/Applications/Android Studio.app" "$HOME/Applications/Android Studio.app"; do
  if [ -x "$app/Contents/jbr/Contents/Home/bin/java" ]; then
    echo "$app/Contents/jbr/Contents/Home"; exit 0
  fi
done
echo "No JDK 17–24 found. Install one (e.g. Amazon Corretto 21) or Android Studio." >&2
exit 1
