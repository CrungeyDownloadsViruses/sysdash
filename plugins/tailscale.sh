#!/usr/bin/env bash
# sysdash plugin: Tailscale tailnet overview
SYSDASH_PLUGIN_ID="tailscale"
SYSDASH_PLUGIN_NAME="TAILSCALE · TAILNET"
SYSDASH_PLUGIN_SPAN="half"

sysdash_plugin_tailscale() {
  local json self_user self_email self_name online offline exit_count exit_list active_exit peers row idx=0
  local allow_un=${SYSDASH_SHOWCASE_UN:-0} allow_oun=${SYSDASH_SHOWCASE_OUN:-0}
  local allow_sn=${SYSDASH_SHOWCASE_SN:-0} allow_osn=${SYSDASH_SHOWCASE_OSN:-0}
  local allow_em=${SYSDASH_SHOWCASE_EM:-0} allow_oem=${SYSDASH_SHOWCASE_OEM:-0}
  local allow_eip=${SYSDASH_SHOWCASE_EIP:-0} allow_oeip=${SYSDASH_SHOWCASE_OEIP:-0}
  local allow_iip=${SYSDASH_SHOWCASE_IIP:-0}
  local showcase=${SYSDASH_SHOWCASE:-0}
  local self_ips peer_ips self_endpoint peer_endpoints

  if ! command -v tailscale >/dev/null 2>&1; then
    box_line "${WARN}tailscale CLI not found${RST}"
    box_line "Install Tailscale or enable its CLI in PATH."
    return 0
  fi

  json=$(plugin_cache_get tailscale 2 2>/dev/null) || json=""
  if [ -z "$json" ]; then
    json=$(tmo 1 tailscale status --json 2>/dev/null)
    [ -n "$json" ] && printf '%s' "$json" | plugin_cache_set tailscale >/dev/null 2>&1
  fi

  if [ -n "$json" ] && command -v jq >/dev/null 2>&1 && printf '%s' "$json" | jq -e '.Self != null or .Peer != null' >/dev/null 2>&1; then
    online=$(printf '%s' "$json" | jq '[.Peer // {} | .[] | select(.Online == true)] | length')
    offline=$(printf '%s' "$json" | jq '[.Peer // {} | .[] | select(.Online != true)] | length')
    exit_count=$(printf '%s' "$json" | jq '[.Peer // {} | .[] | select(.ExitNodeOption == true)] | length')

    self_name=$(printf '%s' "$json" | jq -r '.Self.HostName // .Self.DNSName // "this device"')
    self_user=$(printf '%s' "$json" | jq -r '(.Self.UserID // "") as $id | .User[($id|tostring)].DisplayName // empty')
    self_email=$(printf '%s' "$json" | jq -r '(.Self.UserID // "") as $id | .User[($id|tostring)].LoginName // empty')
    if [ "$showcase" = 1 ]; then
      [ "$allow_sn" = 1 ] || self_name="this device"
      [ "$allow_un" = 1 ] || self_user=""
      [ "$allow_em" = 1 ] || self_email=""
    fi
    box_line "${DIM}Device${RST}  ${ACC}$(trunc "$self_name" 28)${RST}"
    [ -n "$self_user" ] && box_line "${DIM}User${RST}    $(trunc "$self_user" 30)"
    [ -n "$self_email" ] && box_line "${DIM}Email${RST}   $(trunc "$self_email" 32)"
    self_ips=$(printf '%s' "$json" | jq -r '[.Self.TailscaleIPs // [] | .[]] | join(", ")')
    self_endpoint=$(printf '%s' "$json" | jq -r '(.Self.CurAddr // empty) | sub(":[0-9]+$"; "")')
    if [ -n "$self_ips" ] && { [ "$showcase" != 1 ] || [ "$allow_iip" = 1 ]; }; then
      box_line "${DIM}Tailnet IP${RST} $(trunc "$self_ips" 32)"
    fi
    if [ -n "$self_endpoint" ] && { [ "$showcase" != 1 ] || [ "$allow_eip" = 1 ]; }; then
      box_line "${DIM}Endpoint${RST} $(trunc "$self_endpoint" 32)"
    fi
    box_line "${DIM}Peers${RST}   ${OK}${online:-0} online${RST} / ${DIM}${offline:-0} offline${RST}"
    box_line "${DIM}Exit nodes${RST} ${exit_count:-0} available"
    exit_list=$(printf '%s' "$json" | jq -r --arg showname "$((showcase == 0 || allow_osn == 1))" '
      [(.Peer // {} | to_entries[] | select(.value.ExitNodeOption == true)) | if $showname == "1" then (.value.HostName // .value.DNSName // .key) else "exit node" end] | unique | join(", ")
    ' 2>/dev/null)
    [ -n "$exit_list" ] && box_line "${DIM}Advertised${RST} $(trunc "$exit_list" 34)"

    active_exit=$(printf '%s' "$json" | jq -r '(.ExitNodeStatus.ID // "") as $id | if $id == "" then "none" else ((.Peer // {}) | to_entries[]? | select(.key == $id or .value.ID == $id) | (.value.HostName // .value.DNSName // .key)) // "selected exit node" end' | head -n 1)
    if [ "$showcase" = 1 ] && [ "$allow_osn" != 1 ] && [ "$active_exit" != "none" ]; then active_exit="selected exit node"; fi
    box_line "${DIM}Using${RST}   $(trunc "${active_exit:-none}" 30)"

    peers=$(printf '%s' "$json" | jq -r \
      --arg showname "$((showcase == 0 || allow_osn == 1))" \
      --arg showuser "$((showcase == 0 || allow_oun == 1))" \
      --arg showemail "$((showcase == 0 || allow_oem == 1))" \
      --arg showiip "$((showcase == 0 || allow_iip == 1))" \
      --arg showeip "$((showcase == 0 || allow_oeip == 1))" '
      (.User // {}) as $users |
      [(.Peer // {} | to_entries[] | select(.value.Online == true))] | .[:5][] |
      .value as $p | ($p.UserID // "") as $uid |
      ([if $showname == "1" then ($p.HostName // $p.DNSName // "remote device") else "remote device" end,
        (if $showuser == "1" then ($users[($uid|tostring)].DisplayName // empty) else empty end),
        (if $showemail == "1" then ($users[($uid|tostring)].LoginName // empty) else empty end),
        (if $showiip == "1" then (($p.TailscaleIPs // []) | join(",")) else empty end),
        (if $showeip == "1" then (($p.CurAddr // empty) | sub(":[0-9]+$"; "")) else empty end)] | map(select(length > 0)) | join(" · "))
    ' 2>/dev/null)
    if [ -n "$peers" ]; then
      box_line "${DIM}Connected devices${RST}"
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        idx=$((idx + 1)); box_line "  ${OK}●${RST} $(trunc "$row" 34)"
      done <<EOF_PEERS
$peers
EOF_PEERS
    fi
  else
    # Text fallback is deliberately conservative in showcase mode: without
    # structured fields we cannot reliably distinguish self from peer names.
    local fallback
    fallback=$(plugin_cache_get tailscale-text 2 2>/dev/null) || fallback=""
    if [ -z "$fallback" ]; then
      fallback=$(tmo 1 tailscale status 2>/dev/null)
      [ -n "$fallback" ] && printf '%s' "$fallback" | plugin_cache_set tailscale-text >/dev/null 2>&1
    fi
    if [ -z "$fallback" ]; then
      box_line "${WARN}Tailscale is not responding${RST}"
      return 0
    fi
    online=$(printf '%s\n' "$fallback" | awk '$1 ~ /^[0-9]+\./ && $0 !~ /offline/ {n++} END{print n+0}')
    offline=$(printf '%s\n' "$fallback" | awk '$1 ~ /^[0-9]+\./ && /offline/ {n++} END{print n+0}')
    box_line "${DIM}Devices${RST} ${OK}${online} online${RST} / ${DIM}${offline} offline${RST}"
    if [ "$showcase" = 1 ] && [ "$allow_osn" != 1 ]; then
      box_line "${DIM}Device names${RST} hidden (structured status unavailable)"
    else
      box_line "${DIM}Peers${RST}"
      printf '%s\n' "$fallback" | awk '$1 ~ /^[0-9]+\./ {print $2}' | head -n 4 | while IFS= read -r row; do
        [ -n "$row" ] && box_line "  $(trunc "$row" 34)"
      done
    fi
    box_line "${DIM}Exit nodes${RST} $(printf '%s\n' "$fallback" | awk '/offers exit node/ {n++} END{print n+0}') available"
  fi
}
