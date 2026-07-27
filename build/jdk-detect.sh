#!/usr/bin/env bash
# jdk-detect.sh — Shared JDK discovery helpers.
#
# This file is a library. Source it from another build script; it performs no
# work until one of the functions below is called.

# Print the major version from the first line of java (or javac) version output.
javabox_jdk_major() {
  local version_line="$1"
  local major

  major="$(printf '%s\n' "$version_line" | sed -nE \
    's/.*[Vv]ersion[[:space:]]+"?1\.([0-9]+)([^0-9].*)?/\1/p')"
  if [ -n "$major" ]; then
    printf '%s\n' "$major"
    return 0
  fi

  printf '%s\n' "$version_line" | sed -nE \
    -e 's/.*[Vv]ersion[[:space:]]+"?([0-9]+)([^0-9].*)?/\1/p' \
    -e 's/^(openjdk|java|javac)[[:space:]]+([0-9]+)([^0-9].*)?/\2/p'
}

# Return success when a JDK home contains java from one of the accepted majors.
javabox_jdk_matches() {
  local jdk_home="$1"
  local accepted_majors="$2"
  local version_output
  local version_line
  local actual_major
  local accepted_major

  if [ -z "$jdk_home" ] || [ ! -x "$jdk_home/bin/java" ]; then
    JAVABOX_JDK_DETECT_REASON="no executable bin/java at ${jdk_home:-<empty path>}"
    return 1
  fi

  if version_output="$("$jdk_home/bin/java" -version 2>&1)"; then
    version_line="$(printf '%s\n' "$version_output" | sed -n '1p')"
  else
    JAVABOX_JDK_DETECT_REASON="unable to run $jdk_home/bin/java -version"
    return 1
  fi

  actual_major="$(javabox_jdk_major "$version_line")"
  if [ -z "$actual_major" ]; then
    JAVABOX_JDK_DETECT_REASON="unrecognized Java version '$version_line' at $jdk_home"
    return 1
  fi

  JAVABOX_JDK_DETECT_REASON="JDK $actual_major ($version_line) at $jdk_home"
  for accepted_major in $accepted_majors; do
    if [ "$actual_major" = "$accepted_major" ]; then
      return 0
    fi
  done

  return 1
}

# Record and print a matching candidate.
javabox_use_jdk_candidate() {
  local candidate="$1"
  local accepted_majors="$2"

  if javabox_jdk_matches "$candidate" "$accepted_majors"; then
    JAVABOX_JDK_DETECT_RESULT="$candidate"
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

# Find a JDK home in documented priority order.
javabox_find_jdk() {
  local accepted_majors="$1"
  local override_name="$2"
  local override_value
  local candidate
  local major
  local java_command

  JAVABOX_JDK_DETECT_RESULT=""
  JAVABOX_JDK_DETECT_REASON="no JDK candidates were found"

  case "$override_name" in
    [A-Za-z_][A-Za-z0-9_]*) ;;
    *)
      JAVABOX_JDK_DETECT_REASON="invalid override environment variable name '$override_name'"
      return 1
      ;;
  esac

  eval "override_value=\${$override_name-}"
  if [ -n "$override_value" ]; then
    if javabox_use_jdk_candidate "$override_value" "$accepted_majors"; then
      return 0
    fi
    JAVABOX_JDK_DETECT_REASON="$override_name points to $JAVABOX_JDK_DETECT_REASON"
    return 1
  fi

  if [ -n "${JAVA_HOME:-}" ]; then
    if javabox_use_jdk_candidate "$JAVA_HOME" "$accepted_majors"; then
      return 0
    fi
  fi

  for major in $accepted_majors; do
    if [ "$(uname -s)" = "Darwin" ] && [ -x /usr/libexec/java_home ]; then
      if candidate="$(/usr/libexec/java_home -v "$major" 2>/dev/null)"; then
        if [ -n "$candidate" ] && \
           javabox_use_jdk_candidate "$candidate" "$major"; then
          return 0
        fi
      fi
    fi

    candidate="/opt/homebrew/opt/openjdk@$major/libexec/openjdk.jdk/Contents/Home"
    if [ -d "$candidate" ] && \
       javabox_use_jdk_candidate "$candidate" "$major"; then
      return 0
    fi

    candidate="/usr/local/opt/openjdk@$major/libexec/openjdk.jdk/Contents/Home"
    if [ -d "$candidate" ] && \
       javabox_use_jdk_candidate "$candidate" "$major"; then
      return 0
    fi

    if [ "$(uname -s)" = "Linux" ]; then
      for candidate in \
        /usr/lib/jvm/java-"$major"-openjdk* \
        /usr/lib/jvm/jdk-"$major"*; do
        if [ -d "$candidate" ] && \
           javabox_use_jdk_candidate "$candidate" "$major"; then
          return 0
        fi
      done
    fi
  done

  if java_command="$(command -v java 2>/dev/null)"; then
    candidate="$(dirname "$(dirname "$java_command")")"
    if javabox_use_jdk_candidate "$candidate" "$accepted_majors"; then
      return 0
    fi
  fi

  return 1
}

# Print a matching JDK home or terminate the calling build with an actionable
# two-line diagnostic.
javabox_require_jdk() {
  local accepted_majors="$1"
  local override_name="$2"
  local purpose="$3"

  if javabox_find_jdk "$accepted_majors" "$override_name" >/dev/null; then
    printf '%s\n' "$JAVABOX_JDK_DETECT_RESULT"
    return 0
  fi

  printf 'ERROR: Cannot find %s (accepted JDK majors: %s). Found: %s.\n' \
    "$purpose" "$accepted_majors" "$JAVABOX_JDK_DETECT_REASON" >&2
  printf "Set %s to a matching JDK home (macOS: brew install openjdk@21; Linux: install your distro's OpenJDK 21 JDK package).\n" \
    "$override_name" >&2
  exit 1
}
