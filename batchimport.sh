#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
VERBOSE=false
DRY_RUN=false
CONFIG_FILE="settings.json"
LIST_SERIES=false

# Global variables for series mappings
SERIES_MAPPINGS=""
SONARR_URL=""
SONARR_API_KEY=""
AUTO_MATCH=true
SONARR_SERIES_CACHE=""



# Video file extensions
VIDEO_EXTENSIONS=("mkv" "avi" "wmv" "mov" "amv" "mp4" "m4v" "f4v" "mpg" "mp2" "mpeg" "mpe" "mpv")

##############################################################################
# Functions
##############################################################################

log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == true ]]; then
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] VERBOSE:${NC} $*" >&2
  fi
}

log_warning() {
  echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $*" >&2
}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Scan video files and submit them to import into Sonarr

OPTIONS:
    -c, --config FILE    Path to settings JSON file (default: settings.json)
    -v, --verbose        Enable verbose logging
    -d, --dry-run        Dry run - scan files but don't call Sonarr API
    -l, --list-series    List all series in Sonarr with their IDs
    -h, --help           Show this help message

EXAMPLES:
    $0 -c /path/to/settings.json
    $0 --verbose --dry-run
    $0 -c settings.json -v
    $0 --list-series | grep -i "vegas"

CONFIGURATION FILE:
    The configuration file should be in JSON format with the following structure:
    {
      "sonarr": {
        "url": "http://localhost:8989",
        "apiKey": "your-api-key",
        "mappingPath": "/downloads/",
        "downloadsFolder": "/path/to/downloads",
        "importMode": "Copy",
        "timeoutSecs": 5,
        "autoMatch": true,
        "autoMatchMinScore": 70,
        "seriesMappings": []
      }
    }

IMPORT FLOW:
    1. If a seriesMapping exists -> use ManualImport API directly
    2. Otherwise, try to auto-match series name from filename
       - If match found -> use ManualImport API + save mapping
    3. If no match found -> fall back to standard Sonarr scan

AUTO-MATCHING:
    When Sonarr can't recognize a file, the script tries to match the series
    name from the filename to your Sonarr library.

    - autoMatch: Enable/disable auto-matching fallback (default: true)
    - autoMatchMinScore: Minimum similarity score 0-100 (default: 70)

    Example: Sonarr fails on "Las.Vegas.S02E03.mkv" -> script extracts
    "Las Vegas" -> matches to your library -> imports -> saves mapping.

SERIES MAPPINGS:
    Successful auto-matches are saved to seriesMappings. You can also add
    manual mappings for edge cases:

    "seriesMappings": [
      {
        "pattern": "Las[. ]Vegas",
        "seriesId": 123,
        "comment": "Las Vegas (auto-matched)"
      }
    ]

    Use --list-series to find series IDs.

EOF
  exit 0
}

check_dependencies() {
  local missing_deps=()

  if ! command -v jq &>/dev/null; then
    missing_deps+=("jq")
  fi

  if ! command -v curl &>/dev/null; then
    missing_deps+=("curl")
  fi

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    log_error "Missing required dependencies: ${missing_deps[*]}"
    log_error "Please install them before running this script."
    log_error "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
    log_error "  MacOS: brew install ${missing_deps[*]}"
    exit 1
  fi
}

is_video_file() {
  local file="$1"
  local ext="${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  for valid_ext in "${VIDEO_EXTENSIONS[@]}"; do
    if [[ "$ext" == "$valid_ext" ]]; then
      return 0
    fi
  done
  return 1
}

apply_transforms() {
  local filename="$1"
  local transforms_json="$2"
  local new_filename="$filename"

  if [[ -z "$transforms_json" ]] || [[ "$transforms_json" == "null" ]]; then
    log_verbose "No transforms configured"
    return 0
  fi

  local transform_count=$(echo "$transforms_json" | jq 'length')
  log_verbose "Applying $transform_count transform(s) to: $filename"

  for ((i = 0; i < transform_count; i++)); do
    local search=$(echo "$transforms_json" | jq -r ".[$i].search")
    local replace=$(echo "$transforms_json" | jq -r ".[$i].replace")

    # Apply regex transform using sed
    new_filename=$(echo "$new_filename" | sed -E "s/$search/$replace/gI")
    log_verbose "  Transform $((i + 1)): $search -> $replace"
  done

  if [[ "$filename" != "$new_filename" ]]; then
    log "Filename transformed: $filename => $new_filename"
  fi

  echo "$new_filename"
}

rename_file() {
  local old_path="$1"
  local new_filename="$2"
  local dir=$(dirname "$old_path")
  local old_filename=$(basename "$old_path")

  if [[ "$old_filename" == "$new_filename" ]]; then
    echo "$old_path"
    return 0
  fi

  local new_path="$dir/$new_filename"

  log "Renaming file: $old_filename -> $new_filename"

  if mv "$old_path" "$new_path" 2>/dev/null; then
    echo "$new_path"
    return 0
  else
    log_error "Failed to rename file: $old_path"
    echo "$old_path"
    return 1
  fi
}

translate_path() {
  local base_folder="$1"
  local full_path="$2"
  local mapping_path="$3"

  # Remove base folder from full path
  local relative_path="${full_path#$base_folder}"
  relative_path="${relative_path#/}"

  # Combine with mapping path
  local mapped_path="${mapping_path%/}/$relative_path"

  echo "$mapped_path"
}

##############################################################################
# Series Mapping Functions
##############################################################################

# List all series in Sonarr with their IDs
list_sonarr_series() {
  local url="$1"
  local api_key="$2"

  log "Fetching series list from Sonarr..."

  local response=$(curl -s -w "\n%{http_code}" -X GET \
    "${url}/api/v3/series" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${api_key}" \
    -H "User-Agent: SonarrAutoImport-Bash")

  local http_code=$(echo "$response" | tail -n1)
  local response_body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
    echo ""
    echo "ID     | Title (Year)"
    echo "-------|--------------------------------------------------"
    echo "$response_body" | jq -r '.[] | "\(.id)\t| \(.title) (\(.year))"' | sort -t'|' -k2
    echo ""
    echo "Use the ID value in your seriesMappings configuration."
  else
    log_error "Failed to fetch series list. HTTP $http_code"
    log_error "Response: $response_body"
    return 1
  fi
}

# Check if filename matches any series mapping
# Returns: seriesId if matched, empty string otherwise
match_series_mapping() {
  local filename="$1"
  local mappings="$2"

  if [[ -z "$mappings" ]] || [[ "$mappings" == "null" ]] || [[ "$mappings" == "[]" ]]; then
    return 0
  fi

  local mapping_count=$(echo "$mappings" | jq 'length')

  for ((i = 0; i < mapping_count; i++)); do
    local pattern=$(echo "$mappings" | jq -r ".[$i].pattern")
    local series_id=$(echo "$mappings" | jq -r ".[$i].seriesId")
    local comment=$(echo "$mappings" | jq -r ".[$i].comment // \"\"")

    if echo "$filename" | grep -qEi "$pattern"; then
      log_verbose "Matched mapping: '$pattern' -> Series ID $series_id ($comment)"
      echo "$series_id"
      return 0
    fi
  done

  return 0
}

# Parse episode information from filename
# Supports: S01E01, S01E01E02, S01E01-E03, 1x01, etc.
# Returns: JSON with season and episode numbers
parse_episode_info() {
  local filename="$1"

  # Pattern 1: S01E01E02 or S01E01-E02 (multi-episode)
  if [[ "$filename" =~ [Ss]([0-9]+)[Ee]([0-9]+)[-Ee]+([0-9]+) ]]; then
    local season=$((10#${BASH_REMATCH[1]}))
    local ep_start=$((10#${BASH_REMATCH[2]}))
    local ep_end=$((10#${BASH_REMATCH[3]}))
    local episodes="["
    for ((ep = ep_start; ep <= ep_end; ep++)); do
      if [[ "$episodes" != "[" ]]; then
        episodes+=","
      fi
      episodes+="$ep"
    done
    episodes+="]"
    echo "{\"season\": $season, \"episodes\": $episodes}"
    return 0
  fi

  # Pattern 2: S01E01 (single episode)
  if [[ "$filename" =~ [Ss]([0-9]+)[Ee]([0-9]+) ]]; then
    local season=$((10#${BASH_REMATCH[1]}))
    local episode=$((10#${BASH_REMATCH[2]}))
    echo "{\"season\": $season, \"episodes\": [$episode]}"
    return 0
  fi

  # Pattern 3: 1x01 format
  if [[ "$filename" =~ ([0-9]+)[xX]([0-9]+) ]]; then
    local season=$((10#${BASH_REMATCH[1]}))
    local episode=$((10#${BASH_REMATCH[2]}))
    echo "{\"season\": $season, \"episodes\": [$episode]}"
    return 0
  fi

  # No match found
  return 1
}

# Detect quality from filename
# Returns: quality string for Sonarr API
detect_quality() {
  local filename="$1"
  local filename_upper=$(echo "$filename" | tr '[:lower:]' '[:upper:]')

  # Check for common quality indicators (order matters - check highest first)
  if [[ "$filename_upper" =~ (2160P|4K|UHD) ]]; then
    echo "WEBDL-2160p"
  elif [[ "$filename_upper" =~ BLURAY ]] && [[ "$filename_upper" =~ 1080P ]]; then
    echo "Bluray-1080p"
  elif [[ "$filename_upper" =~ BLURAY ]] && [[ "$filename_upper" =~ 720P ]]; then
    echo "Bluray-720p"
  elif [[ "$filename_upper" =~ BLURAY ]]; then
    echo "Bluray-1080p"
  elif [[ "$filename_upper" =~ (WEBDL|WEB-DL|WEB\.DL) ]] && [[ "$filename_upper" =~ 1080P ]]; then
    echo "WEBDL-1080p"
  elif [[ "$filename_upper" =~ (WEBDL|WEB-DL|WEB\.DL) ]] && [[ "$filename_upper" =~ 720P ]]; then
    echo "WEBDL-720p"
  elif [[ "$filename_upper" =~ (WEBDL|WEB-DL|WEB\.DL) ]]; then
    echo "WEBDL-1080p"
  elif [[ "$filename_upper" =~ (WEBRIP|WEB-RIP|WEB\.RIP) ]] && [[ "$filename_upper" =~ 1080P ]]; then
    echo "WEBRip-1080p"
  elif [[ "$filename_upper" =~ (WEBRIP|WEB-RIP|WEB\.RIP) ]] && [[ "$filename_upper" =~ 720P ]]; then
    echo "WEBRip-720p"
  elif [[ "$filename_upper" =~ (WEBRIP|WEB-RIP|WEB\.RIP) ]]; then
    echo "WEBRip-720p"
  elif [[ "$filename_upper" =~ HDTV ]] && [[ "$filename_upper" =~ 1080P ]]; then
    echo "HDTV-1080p"
  elif [[ "$filename_upper" =~ HDTV ]] && [[ "$filename_upper" =~ 720P ]]; then
    echo "HDTV-720p"
  elif [[ "$filename_upper" =~ HDTV ]]; then
    echo "HDTV-720p"
  elif [[ "$filename_upper" =~ (DVDRIP|DVD-RIP|DVD\.RIP|DVDR) ]]; then
    echo "DVD"
  elif [[ "$filename_upper" =~ 1080P ]]; then
    echo "WEBDL-1080p"
  elif [[ "$filename_upper" =~ 720P ]]; then
    echo "WEBDL-720p"
  elif [[ "$filename_upper" =~ 480P ]]; then
    echo "SDTV"
  else
    echo "SDTV"
  fi
}

# Get quality ID from quality name
get_quality_id() {
  local quality_name="$1"

  case "$quality_name" in
    "SDTV") echo 1 ;;
    "DVD") echo 2 ;;
    "WEBDL-480p") echo 8 ;;
    "HDTV-720p") echo 4 ;;
    "HDTV-1080p") echo 9 ;;
    "WEBRip-720p") echo 14 ;;
    "WEBDL-720p") echo 5 ;;
    "Bluray-720p") echo 6 ;;
    "WEBRip-1080p") echo 15 ;;
    "WEBDL-1080p") echo 3 ;;
    "Bluray-1080p") echo 7 ;;
    "WEBDL-2160p") echo 18 ;;
    "Bluray-2160p") echo 19 ;;
    *) echo 0 ;;  # Unknown
  esac
}

# Detect language from filename
detect_language() {
  local filename="$1"
  local filename_upper=$(echo "$filename" | tr '[:lower:]' '[:upper:]')

  # Check for common language indicators
  if [[ "$filename_upper" =~ (FRENCH|TRUEFRENCH|VFF|VFI) ]]; then
    echo "french"
  elif [[ "$filename_upper" =~ (GERMAN|DEUTSCH) ]]; then
    echo "german"
  elif [[ "$filename_upper" =~ (SPANISH|ESPANOL) ]]; then
    echo "spanish"
  elif [[ "$filename_upper" =~ (ITALIAN|ITALIANO) ]]; then
    echo "italian"
  elif [[ "$filename_upper" =~ (JAPANESE|JAP) ]]; then
    echo "japanese"
  elif [[ "$filename_upper" =~ (KOREAN|KOR) ]]; then
    echo "korean"
  elif [[ "$filename_upper" =~ (CHINESE|CHI) ]]; then
    echo "chinese"
  elif [[ "$filename_upper" =~ (RUSSIAN|RUS) ]]; then
    echo "russian"
  elif [[ "$filename_upper" =~ (PORTUGUESE|PORT) ]]; then
    echo "portuguese"
  elif [[ "$filename_upper" =~ (DUTCH|NL) ]]; then
    echo "dutch"
  else
    echo "english"
  fi
}

# Get language ID from language name
get_language_id() {
  local language_name="$1"

  case "$language_name" in
    "english") echo 1 ;;
    "french") echo 2 ;;
    "spanish") echo 3 ;;
    "german") echo 4 ;;
    "italian") echo 5 ;;
    "danish") echo 6 ;;
    "dutch") echo 7 ;;
    "japanese") echo 8 ;;
    "icelandic") echo 9 ;;
    "chinese") echo 10 ;;
    "russian") echo 11 ;;
    "polish") echo 12 ;;
    "vietnamese") echo 13 ;;
    "swedish") echo 14 ;;
    "norwegian") echo 15 ;;
    "finnish") echo 16 ;;
    "turkish") echo 17 ;;
    "portuguese") echo 18 ;;
    "flemish") echo 19 ;;
    "greek") echo 20 ;;
    "korean") echo 21 ;;
    "hungarian") echo 22 ;;
    "hebrew") echo 23 ;;
    "lithuanian") echo 24 ;;
    "czech") echo 25 ;;
    *) echo 1 ;;  # Default to English
  esac
}

# Extract release group from filename
extract_release_group() {
  local filename="$1"

  # Try to match common release group patterns
  # Usually at the end before extension, after a dash
  if [[ "$filename" =~ -([A-Za-z0-9]+)\.[a-zA-Z0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  echo ""
}

##############################################################################
# Auto-Matching Functions
##############################################################################

# Save a successful auto-match to seriesMappings in settings.json
save_mapping_to_config() {
  local config_file="$1"
  local extracted_name="$2"
  local series_id="$3"
  local series_title="$4"

  # Don't save during dry-run
  if [[ "$DRY_RUN" == true ]]; then
    log_verbose "[DRY-RUN] Would save mapping: '$extracted_name' -> $series_title (ID: $series_id)"
    return 0
  fi

  if [[ -z "$config_file" ]] || [[ ! -f "$config_file" ]]; then
    return 1
  fi

  # Create a pattern from the extracted name (escape dots for regex)
  local pattern=$(echo "$extracted_name" | sed 's/\./\\./g; s/ /[. ]/g')

  # Check if this pattern already exists in seriesMappings
  local existing=$(jq -r ".sonarr.seriesMappings // [] | .[] | select(.seriesId == $series_id) | .seriesId" "$config_file" 2>/dev/null)

  if [[ -n "$existing" ]]; then
    log_verbose "Mapping already exists for series ID $series_id"
    return 0
  fi

  # Add new mapping to settings.json
  local new_mapping=$(jq -n \
    --arg pattern "$pattern" \
    --argjson seriesId "$series_id" \
    --arg comment "$series_title (auto-matched)" \
    '{pattern: $pattern, seriesId: $seriesId, comment: $comment}')

  # Update the config file
  local updated_config=$(jq ".sonarr.seriesMappings = (.sonarr.seriesMappings // []) + [$new_mapping]" "$config_file")

  if [[ -n "$updated_config" ]]; then
    echo "$updated_config" > "$config_file"
    log "Saved new mapping: '$pattern' -> $series_title (ID: $series_id)"
    
    # Update the in-memory mappings
    SERIES_MAPPINGS=$(echo "$updated_config" | jq -c '.sonarr.seriesMappings // []')
    return 0
  fi

  return 1
}

# Extract series name from filename (everything before S01E01 or similar patterns)
extract_series_name() {
  local filename="$1"
  local series_name=""

  # Remove file extension
  local name_without_ext="${filename%.*}"

  # Pattern 1: Everything before S01E01 pattern
  if [[ "$name_without_ext" =~ ^(.+)[._\ ][Ss][0-9]+[Ee][0-9]+ ]]; then
    series_name="${BASH_REMATCH[1]}"
  # Pattern 2: Everything before 1x01 pattern
  elif [[ "$name_without_ext" =~ ^(.+)[._\ ][0-9]+[xX][0-9]+ ]]; then
    series_name="${BASH_REMATCH[1]}"
  # Pattern 3: Everything before year pattern like (2003) or .2003.
  elif [[ "$name_without_ext" =~ ^(.+)[._\ ]\(?[0-9]{4}\)? ]]; then
    series_name="${BASH_REMATCH[1]}"
  else
    # No pattern matched, return empty
    return 1
  fi

  # Clean up the series name:
  # - Replace dots and underscores with spaces
  # - Remove common tags (quality, language, etc.)
  series_name=$(echo "$series_name" | sed -E '
    s/[._]/ /g;
    s/  +/ /g;
    s/ +$//;
    s/^ +//;
  ')

  # Remove common quality/language tags that might be before S01E01
  series_name=$(echo "$series_name" | sed -E '
    s/ (TRUEFRENCH|FRENCH|VOSTFR|MULTI|MULTi|GERMAN|SPANISH|ITALIAN|HDTV|WEB-DL|WEBDL|WEBRIP|DVDRIP|BLURAY|720p|1080p|2160p|x264|x265|H264|H265|AC3|DTS|AAC).*$//gi;
  ')

  # Trim whitespace
  series_name=$(echo "$series_name" | sed -E 's/^ +//; s/ +$//')

  if [[ -n "$series_name" ]]; then
    echo "$series_name"
    return 0
  fi

  return 1
}

# Normalize a string for comparison (lowercase, remove special chars)
normalize_string() {
  local str="$1"
  echo "$str" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]//g'
}

# Calculate similarity between two strings (simple matching)
# Returns a score from 0-100
calculate_similarity() {
  local str1="$1"
  local str2="$2"

  local norm1=$(normalize_string "$str1")
  local norm2=$(normalize_string "$str2")

  # Exact match
  if [[ "$norm1" == "$norm2" ]]; then
    echo 100
    return 0
  fi

  # Check if one contains the other
  if [[ "$norm1" == *"$norm2"* ]] || [[ "$norm2" == *"$norm1"* ]]; then
    # Calculate containment score based on length ratio
    local len1=${#norm1}
    local len2=${#norm2}
    local shorter=$((len1 < len2 ? len1 : len2))
    local longer=$((len1 > len2 ? len1 : len2))
    if [[ $longer -eq 0 ]]; then
      echo 0
      return 0
    fi
    local score=$((shorter * 100 / longer))
    # Boost score for containment
    score=$((score + 20))
    if [[ $score -gt 100 ]]; then
      score=100
    fi
    echo "$score"
    return 0
  fi

  # Check word-by-word matching
  local words1=($str1)
  local words2=($str2)
  local matching_words=0

  for word1 in "${words1[@]}"; do
    local norm_word1=$(normalize_string "$word1")
    if [[ ${#norm_word1} -lt 2 ]]; then
      continue
    fi
    for word2 in "${words2[@]}"; do
      local norm_word2=$(normalize_string "$word2")
      if [[ "$norm_word1" == "$norm_word2" ]]; then
        ((matching_words++))
        break
      fi
    done
  done

  local total_words=${#words1[@]}
  if [[ $total_words -eq 0 ]]; then
    echo 0
    return 0
  fi

  local score=$((matching_words * 100 / total_words))
  echo "$score"
}

# Fetch and cache all series from Sonarr
fetch_sonarr_series() {
  local url="$1"
  local api_key="$2"

  # Return cached data if available
  if [[ -n "$SONARR_SERIES_CACHE" ]]; then
    echo "$SONARR_SERIES_CACHE"
    return 0
  fi

  log_verbose "Fetching series list from Sonarr for auto-matching..."

  local response=$(curl -s -w "\n%{http_code}" -X GET \
    "${url}/api/v3/series" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${api_key}" \
    -H "User-Agent: SonarrAutoImport-Bash")

  local http_code=$(echo "$response" | tail -n1)
  local response_body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
    # Validate JSON
    if ! echo "$response_body" | jq -e . >/dev/null 2>&1; then
      log_error "Invalid JSON response from Sonarr API"
      return 1
    fi
    SONARR_SERIES_CACHE="$response_body"
    echo "$response_body"
    return 0
  else
    log_error "Failed to fetch series list. HTTP $http_code"
    log_verbose "Response: $response_body"
    return 1
  fi
}

# Auto-match a filename to a series in the Sonarr library
# Returns: JSON with seriesId and title if match found, empty otherwise
auto_match_series() {
  local filename="$1"
  local url="$2"
  local api_key="$3"
  local min_score="${4:-70}"  # Minimum similarity score (default 70%)

  # Extract series name from filename
  local extracted_name=$(extract_series_name "$filename")

  if [[ -z "$extracted_name" ]]; then
    log_verbose "Could not extract series name from: $filename"
    return 1
  fi

  log_verbose "Extracted series name: '$extracted_name'"

  # Fetch series list from Sonarr
  local series_list=$(fetch_sonarr_series "$url" "$api_key")

  if [[ -z "$series_list" ]]; then
    return 1
  fi

  local best_match_id=""
  local best_match_title=""
  local best_match_score=0

  # Iterate through all series and find the best match
  local series_count=$(echo "$series_list" | jq 'length' 2>/dev/null)
  
  if [[ -z "$series_count" ]] || ! [[ "$series_count" =~ ^[0-9]+$ ]]; then
    log_error "Failed to parse series list from Sonarr"
    return 1
  fi

  for ((i = 0; i < series_count; i++)); do
    local series_id=$(echo "$series_list" | jq -r ".[$i].id")
    local series_title=$(echo "$series_list" | jq -r ".[$i].title")
    local series_alt_titles=$(echo "$series_list" | jq -r ".[$i].alternateTitles // [] | .[].title" 2>/dev/null)

    # Check main title
    local score=$(calculate_similarity "$extracted_name" "$series_title")

    if [[ $score -gt $best_match_score ]]; then
      best_match_score=$score
      best_match_id=$series_id
      best_match_title=$series_title
    fi

    # Check alternate titles
    while IFS= read -r alt_title; do
      if [[ -n "$alt_title" ]]; then
        local alt_score=$(calculate_similarity "$extracted_name" "$alt_title")
        if [[ $alt_score -gt $best_match_score ]]; then
          best_match_score=$alt_score
          best_match_id=$series_id
          best_match_title=$series_title
        fi
      fi
    done <<< "$series_alt_titles"
  done

  # Check if we have a good enough match
  if [[ $best_match_score -ge $min_score ]]; then
    log_verbose "Auto-matched '$extracted_name' -> '$best_match_title' (ID: $best_match_id, score: $best_match_score%)"

    # Save mapping to settings.json for future use
    save_mapping_to_config "$CONFIG_FILE" "$extracted_name" "$best_match_id" "$best_match_title"

    # Use jq to properly escape the title for JSON
    jq -n --argjson id "$best_match_id" --arg title "$best_match_title" --argjson score "$best_match_score" \
      '{seriesId: $id, title: $title, score: $score}'
    return 0
  else
    log_verbose "No good match found for '$extracted_name' (best score: $best_match_score%)"
    return 1
  fi
}

# Get episode IDs from Sonarr for a given series and season/episode numbers
get_episode_ids() {
  local url="$1"
  local api_key="$2"
  local series_id="$3"
  local episode_info="$4"

  local season=$(echo "$episode_info" | jq -r '.season')
  local episodes=$(echo "$episode_info" | jq -r '.episodes[]')

  log_verbose "Looking up episodes for series $series_id, season $season"

  # Fetch all episodes for the series and season
  local response=$(curl -s -w "\n%{http_code}" -X GET \
    "${url}/api/v3/episode?seriesId=${series_id}&seasonNumber=${season}" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${api_key}" \
    -H "User-Agent: SonarrAutoImport-Bash")

  local http_code=$(echo "$response" | tail -n1)
  local response_body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -lt 200 ]] || [[ "$http_code" -ge 300 ]]; then
    log_error "Failed to fetch episodes. HTTP $http_code"
    return 1
  fi

  # Build array of episode IDs
  local episode_ids="[]"
  for ep_num in $episodes; do
    local ep_id=$(echo "$response_body" | jq -r ".[] | select(.episodeNumber == $ep_num) | .id")
    if [[ -n "$ep_id" ]] && [[ "$ep_id" != "null" ]]; then
      episode_ids=$(echo "$episode_ids" | jq ". + [$ep_id]")
      log_verbose "Found episode $ep_num -> ID $ep_id"
    else
      log_warning "Episode $ep_num not found in Sonarr for series $series_id season $season"
      return 1
    fi
  done

  echo "$episode_ids"
}

# Get series name from Sonarr
get_series_name() {
  local url="$1"
  local api_key="$2"
  local series_id="$3"

  local response=$(curl -s -X GET \
    "${url}/api/v3/series/${series_id}" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${api_key}" \
    -H "User-Agent: SonarrAutoImport-Bash")

  echo "$response" | jq -r '.title // "Unknown"'
}

# Call Sonarr ManualImport API to import a file with explicit series/episode assignment
call_manual_import_api() {
  local url="$1"
  local api_key="$2"
  local remote_path="$3"
  local series_id="$4"
  local episode_ids="$5"
  local import_mode="$6"
  local quality_name="$7"
  local language_name="$8"
  local release_group="$9"

  local quality_id=$(get_quality_id "$quality_name")
  local language_id=$(get_language_id "$language_name")
  local folder_path=$(dirname "$remote_path")

  log_verbose "Manual import: series=$series_id, episodes=$episode_ids, quality=$quality_name($quality_id), lang=$language_name($language_id)"

  # First, get the manual import preview to get the file info
  # URL encode the folder path
  local encoded_folder=$(echo -n "$folder_path" | jq -sRr @uri)
  
  log_verbose "Scanning folder: $folder_path"
  
  local preview_response=$(curl -s -w "\n%{http_code}" -X GET \
    "${url}/api/v3/manualimport?folder=${encoded_folder}&filterExistingFiles=false" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${api_key}" \
    -H "User-Agent: SonarrAutoImport-Bash")

  local preview_http_code=$(echo "$preview_response" | tail -n1)
  local preview_body=$(echo "$preview_response" | sed '$d')

  if [[ "$preview_http_code" -lt 200 ]] || [[ "$preview_http_code" -ge 300 ]]; then
    log_error "Failed to get manual import preview. HTTP $preview_http_code"
    log_verbose "Response: $preview_body"
    return 1
  fi

  # Check if we got any files
  local file_count=$(echo "$preview_body" | jq 'length' 2>/dev/null || echo "0")
  log_verbose "Found $file_count file(s) in folder scan"

  if [[ "$file_count" == "0" ]]; then
    log_error "No files found in folder: $folder_path"
    log_verbose "Make sure the path is accessible to Sonarr"
    return 1
  fi

  # Find the file in the preview response
  local filename=$(basename "$remote_path")
  local file_entry=$(echo "$preview_body" | jq --arg path "$remote_path" --arg name "$filename" \
    'first(.[] | select(.path == $path or .name == $name))' 2>/dev/null)

  if [[ -z "$file_entry" ]] || [[ "$file_entry" == "null" ]]; then
    log_verbose "File not found by exact path, trying by filename only..."
    file_entry=$(echo "$preview_body" | jq --arg name "$filename" \
      'first(.[] | select(.name == $name))' 2>/dev/null)
  fi

  if [[ -z "$file_entry" ]] || [[ "$file_entry" == "null" ]]; then
    log_error "File not found in manual import preview: $filename"
    log_verbose "Available files:"
    echo "$preview_body" | jq -r '.[].name' 2>/dev/null | while read -r f; do
      log_verbose "  - $f"
    done
    return 1
  fi

  local file_id=$(echo "$file_entry" | jq -r '.id')
  local file_path=$(echo "$file_entry" | jq -r '.path')

  log_verbose "Found file in preview: ID=$file_id, path=$file_path"

  # Build the manual import payload
  local payload=$(jq -n \
    --argjson id "$file_id" \
    --arg path "$file_path" \
    --argjson seriesId "$series_id" \
    --argjson episodeIds "$episode_ids" \
    --argjson qualityId "$quality_id" \
    --arg qualityName "$quality_name" \
    --argjson languageId "$language_id" \
    --arg languageName "$language_name" \
    --arg releaseGroup "$release_group" \
    '[{
      "id": $id,
      "path": $path,
      "seriesId": $seriesId,
      "episodeIds": $episodeIds,
      "quality": {
        "quality": {
          "id": $qualityId,
          "name": $qualityName
        },
        "revision": {
          "version": 1,
          "real": 0,
          "isRepack": false
        }
      },
      "languages": [{
        "id": $languageId,
        "name": $languageName
      }],
      "releaseGroup": $releaseGroup,
      "indexerFlags": 0,
      "releaseType": "singleEpisode"
    }]')

  log_verbose "Manual import payload: $payload"

  # Execute the manual import command
  local import_mode_lower=$(echo "$import_mode" | tr '[:upper:]' '[:lower:]')
  
  local response=$(curl -s -w "\n%{http_code}" -X POST \
    "${url}/api/v3/command" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${api_key}" \
    -H "User-Agent: SonarrAutoImport-Bash" \
    -d "$(jq -n \
      --argjson files "$payload" \
      --arg importMode "$import_mode_lower" \
      '{
        "name": "ManualImport",
        "files": $files,
        "importMode": $importMode
      }')")

  local http_code=$(echo "$response" | tail -n1)
  local response_body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
    log " - Manual import queued for: $(basename "$remote_path")"
    if [[ "$VERBOSE" == true ]]; then
      echo "$response_body" | jq '.' >&2 2>/dev/null || echo "$response_body" >&2
    fi
    return 0
  else
    log_error "Manual import failed with status $http_code"
    log_verbose "Response: $response_body"
    return 1
  fi
}

##############################################################################
# Standard API Functions
##############################################################################

call_sonarr_api() {
  local url="$1"
  local api_key="$2"
  local remote_path="$3"
  local import_mode="$4"

  local payload=$(jq -n \
    --arg path "$remote_path" \
    --arg mode "$import_mode" \
    '{
            name: "DownloadedEpisodesScan",
            path: $path,
            importMode: $mode,
            downloadClientId: "SonarrAutoImporter"
        }')

  log_verbose "API Payload: $payload"

  local response=$(curl -s -w "\n%{http_code}" -X POST \
    "${url}/api/v3/command" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${api_key}" \
    -H "User-Agent: SonarrAutoImport-Bash" \
    -d "$payload")

  local http_code=$(echo "$response" | tail -n1)
  local response_body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
    log " - Executed Sonarr command for: $remote_path"
    if [[ "$VERBOSE" == true ]]; then
      echo "$response_body" | jq '.' 2>/dev/null || echo "$response_body"
    fi
    return 0
  else
    log_error "API request failed with status $http_code"
    log_error "Response: $response_body"
    return 1
  fi
}

process_sonarr() {
  local config="$1"

  # Read configuration
  local url=$(echo "$config" | jq -r '.url')
  local api_key=$(echo "$config" | jq -r '.apiKey')
  local mapping_path=$(echo "$config" | jq -r '.mappingPath')
  local downloads_folder=$(echo "$config" | jq -r '.downloadsFolder')
  local import_mode=$(echo "$config" | jq -r '.importMode // "Move"')
  local timeout_secs=$(echo "$config" | jq -r '.timeoutSecs // 5')
  local trim_folders=$(echo "$config" | jq -r '.trimFolders // false')
  local transforms=$(echo "$config" | jq -c '.transforms // []')
  local series_mappings=$(echo "$config" | jq -c '.seriesMappings // []')
  local auto_match=$(echo "$config" | jq -r '.autoMatch // true')
  local auto_match_score=$(echo "$config" | jq -r '.autoMatchMinScore // 70')

  # Store in global variables for helper functions
  SONARR_URL="$url"
  SONARR_API_KEY="$api_key"
  SERIES_MAPPINGS="$series_mappings"
  AUTO_MATCH="$auto_match"

  # Validate import mode
  if [[ "$import_mode" != "Copy" ]] && [[ "$import_mode" != "Move" ]]; then
    log_error "Invalid importMode '$import_mode' in settings. Defaulting to 'Move'"
    import_mode="Move"
  fi

  log "Starting video processing for: $downloads_folder"

  local mapping_count=$(echo "$series_mappings" | jq 'length')

  if [[ "$VERBOSE" == true ]]; then
    log " Base URL:        $url"
    log " API Key:         ${api_key:0:8}..."
    log " Mapping:         $mapping_path"
    log " Timeout:         $timeout_secs"
    log " Import Mode:     $import_mode"
    log " Trim Folders:    $trim_folders"
    log " Series Mappings: $mapping_count configured"
    log " Auto-Match:      $auto_match (min score: $auto_match_score%)"
    log " Dry Run:         $DRY_RUN"
  fi

  # Check if directory exists
  if [[ ! -d "$downloads_folder" ]]; then
    log_error "Folder $downloads_folder was not found. Check configuration."
    return 1
  fi

  # Find all video files
  local video_files=()
  while IFS= read -r -d '' file; do
    if is_video_file "$file"; then
      video_files+=("$file")
    fi
  done < <(find "$downloads_folder" -type f -print0)

  if [[ ${#video_files[@]} -eq 0 ]]; then
    log "No videos found. Nothing to do!"
    return 0
  fi

  log "Processing ${#video_files[@]} video file(s)..."

  local success=true
  local skipped=0
  local imported=0

  for video_file in "${video_files[@]}"; do
    local filename=$(basename "$video_file")
    local new_filename=$(apply_transforms "$filename" "$transforms")
    local video_path="$video_file"

    # Rename file if transforms were applied
    if [[ "$filename" != "$new_filename" ]] && [[ "$DRY_RUN" == false ]]; then
      video_path=$(rename_file "$video_file" "$new_filename")
      filename="$new_filename"
    fi

    # Translate path for Sonarr
    local remote_path=$(translate_path "$downloads_folder" "$video_path" "$mapping_path")

    # Check if filename matches any series mapping (manual or previously auto-matched)
    local matched_series_id=$(match_series_mapping "$filename" "$series_mappings")
    local series_name=""
    local match_source=""

    if [[ -n "$matched_series_id" ]]; then
      # We have an explicit mapping - use ManualImport API
      match_source="mapping"
      log_verbose "Using series mapping for: $filename -> Series ID $matched_series_id"

      # Parse episode info from filename
      local episode_info=$(parse_episode_info "$filename")

      if [[ -z "$episode_info" ]]; then
        log_warning "Could not parse episode info from: $filename (skipping)"
        ((skipped++))
        continue
      fi

      local season=$(echo "$episode_info" | jq -r '.season')
      local episodes=$(echo "$episode_info" | jq -r '.episodes | join(", ")')
      log_verbose "Parsed: Season $season, Episode(s) $episodes"

      # Detect quality and language
      local quality_name=$(detect_quality "$filename")
      local language_name=$(detect_language "$filename")
      local release_group=$(extract_release_group "$filename")

      log_verbose "Detected: quality=$quality_name, language=$language_name, group=$release_group"

      if [[ "$DRY_RUN" == true ]]; then
        series_name=$(get_series_name "$url" "$api_key" "$matched_series_id")
        log "[DRY-RUN] Would import (via mapping): $filename"
        log "[DRY-RUN]   -> Series: $series_name (ID: $matched_series_id)"
        log "[DRY-RUN]   -> Season: $season, Episode(s): $episodes"
        log "[DRY-RUN]   -> Quality: $quality_name, Language: $language_name"
        ((imported++))
      else
        # Get episode IDs from Sonarr
        local episode_ids=$(get_episode_ids "$url" "$api_key" "$matched_series_id" "$episode_info")

        if [[ -z "$episode_ids" ]] || [[ "$episode_ids" == "[]" ]]; then
          log_warning "Could not find episodes in Sonarr for: $filename (skipping)"
          ((skipped++))
          continue
        fi

        # Call ManualImport API
        if call_manual_import_api "$url" "$api_key" "$remote_path" "$matched_series_id" "$episode_ids" "$import_mode" "$quality_name" "$language_name" "$release_group"; then
          ((imported++))
        else
          success=false
        fi
      fi
    else
      # No mapping found - try auto-match first, then fall back to standard scan
      local import_success=false
      
      if [[ "$auto_match" == "true" ]]; then
        # Try to auto-match the series
        log_verbose "Trying auto-match for $filename"
        
        local auto_match_result=$(auto_match_series "$filename" "$url" "$api_key" "$auto_match_score")
        
        if [[ -n "$auto_match_result" ]] && echo "$auto_match_result" | jq -e . >/dev/null 2>&1; then
          matched_series_id=$(echo "$auto_match_result" | jq -r '.seriesId' 2>/dev/null)
          series_name=$(echo "$auto_match_result" | jq -r '.title' 2>/dev/null)
          local match_score=$(echo "$auto_match_result" | jq -r '.score' 2>/dev/null)
          
          log "Auto-matched: $filename -> $series_name (${match_score}% confidence)"
          
          # Parse episode info
          local episode_info=$(parse_episode_info "$filename")
          
          if [[ -n "$episode_info" ]]; then
            local season=$(echo "$episode_info" | jq -r '.season')
            local episodes=$(echo "$episode_info" | jq -r '.episodes | join(", ")')
            
            # Detect quality and language
            local quality_name=$(detect_quality "$filename")
            local language_name=$(detect_language "$filename")
            local release_group=$(extract_release_group "$filename")
            
            if [[ "$DRY_RUN" == true ]]; then
              log "[DRY-RUN] Would import (auto-matched): $filename"
              log "[DRY-RUN]   -> Series: $series_name (ID: $matched_series_id)"
              log "[DRY-RUN]   -> Season: $season, Episode(s): $episodes"
              log "[DRY-RUN]   -> Quality: $quality_name, Language: $language_name"
              ((imported++))
              import_success=true
            else
              # Get episode IDs
              local episode_ids=$(get_episode_ids "$url" "$api_key" "$matched_series_id" "$episode_info")
              
              if [[ -n "$episode_ids" ]] && [[ "$episode_ids" != "[]" ]]; then
                # Call ManualImport API
                if call_manual_import_api "$url" "$api_key" "$remote_path" "$matched_series_id" "$episode_ids" "$import_mode" "$quality_name" "$language_name" "$release_group"; then
                  ((imported++))
                  import_success=true
                else
                  log_verbose "Manual import failed, will try standard scan..."
                fi
              else
                log_verbose "Could not find episodes, will try standard scan..."
              fi
            fi
          else
            log_verbose "Could not parse episode info, will try standard scan..."
          fi
        else
          log_verbose "No auto-match found, will try standard scan..."
        fi
      fi
      
      # If auto-match didn't work, fall back to standard Sonarr scan
      if [[ "$import_success" == false ]]; then
        log_verbose "Using standard Sonarr scan..."
        
        if [[ "$DRY_RUN" == true ]]; then
          log "[DRY-RUN] Standard scan: $remote_path"
          ((imported++))
        else
          if call_sonarr_api "$url" "$api_key" "$remote_path" "$import_mode"; then
            ((imported++))
          else
            log_error "Import failed for: $filename"
            success=false
          fi
        fi
      fi
    fi

    # Sleep between files if configured
    if [[ "$timeout_secs" -gt 0 ]] && [[ "$DRY_RUN" == false ]]; then
      log_verbose "Sleeping for $timeout_secs seconds..."
      sleep "$timeout_secs"
    fi
  done

  log ""
  log "Summary: $imported imported, $skipped skipped"

  if [[ "$success" == true ]]; then
    log "All processing completed successfully."
  else
    log "Processing completed with errors."
  fi
}

##############################################################################
# Main
##############################################################################

main() {
  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
    -c | --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    -v | --verbose)
      VERBOSE=true
      shift
      ;;
    -d | --dry-run)
      DRY_RUN=true
      shift
      ;;
    -l | --list-series)
      LIST_SERIES=true
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
    esac
  done

  # Check dependencies
  check_dependencies

  # Check if config file exists
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    exit 1
  fi

  log "Reading configuration from: $CONFIG_FILE"

  # Read and validate JSON
  if ! config_json=$(jq '.' "$CONFIG_FILE" 2>&1); then
    log_error "Invalid JSON in configuration file: $config_json"
    exit 1
  fi

  # Extract Sonarr configuration
  sonarr_config=$(echo "$config_json" | jq '.sonarr')

  if [[ "$sonarr_config" == "null" ]]; then
    log_error "No Sonarr configuration found in $CONFIG_FILE"
    exit 1
  fi

  # Extract URL and API key for helper commands
  local url=$(echo "$sonarr_config" | jq -r '.url')
  local api_key=$(echo "$sonarr_config" | jq -r '.apiKey')

  # Handle --list-series command
  if [[ "$LIST_SERIES" == true ]]; then
    list_sonarr_series "$url" "$api_key"
    exit 0
  fi

  # Process Sonarr
  log "Processing videos for Sonarr..."
  process_sonarr "$sonarr_config"

  log "Done!"
}

# Run main function
main "$@"
