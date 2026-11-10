#!/usr/bin/env bash
SYSDASH_PLUGIN_ID="lastfm"
SYSDASH_PLUGIN_NAME="Last.fm"
SYSDASH_PLUGIN_SPAN="half"

sysdash_plugin_lastfm() {
    local width=$1
    local api_key="${LASTFM_API_KEY:-}"
    local user="${LASTFM_USER:-}"
    
    if [ -z "$api_key" ] || [ -z "$user" ]; then
        box_line "${DIM}Set keys:${RST}"
        box_line "${DIM}  sysdash keys set LASTFM_API_KEY <key>${RST}"
        box_line "${DIM}  sysdash keys set LASTFM_USER <user>${RST}"
        return
    fi

    local url="http://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=${user}&api_key=${api_key}&format=json&limit=1"
    local json
    json=$(tmo 5 curl -fsS "$url" 2>/dev/null)
    
    if [ -z "$json" ]; then
        box_line "${BAD}Failed to fetch Last.fm data${RST}"
        return
    fi

    local track artist album nowplaying parsed
    if have jq; then
        nowplaying=$(printf '%s' "$json" | jq -r '.recenttracks.track[0]["@attr"].nowplaying // "false"')
        track=$(printf '%s' "$json" | jq -r '.recenttracks.track[0].name')
        artist=$(printf '%s' "$json" | jq -r '.recenttracks.track[0].artist["#text"]')
        album=$(printf '%s' "$json" | jq -r '.recenttracks.track[0].album["#text"]')
    elif have python3; then
        parsed=$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    t = d["recenttracks"]["track"][0]
    np = t.get("@attr", {}).get("nowplaying", "false")
    print(np)
    print(t["name"])
    print(t["artist"]["#text"])
    print(t["album"]["#text"])
except Exception:
    print("false")
    print("")
    print("")
    print("")')
        nowplaying=$(echo "$parsed" | sed -n '1p')
        track=$(echo "$parsed" | sed -n '2p')
        artist=$(echo "$parsed" | sed -n '3p')
        album=$(echo "$parsed" | sed -n '4p')
    else
        box_line "${DIM}Install jq or python3 to parse JSON${RST}"
        return
    fi

    if [ "$nowplaying" = "true" ]; then
        box_line "${OK}▶ Now Playing${RST}"
    else
        box_line "${DIM}Last Played${RST}"
    fi
    
    box_line "${BOLD}${track:-Unknown}${RST}"
    box_line "${DIM}by ${artist:-Unknown}${RST}"
    if [ -n "$album" ]; then
        box_line "${DIM}on ${album}${RST}"
    fi
}
