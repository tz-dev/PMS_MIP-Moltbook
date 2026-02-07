#!/usr/bin/env bash
set -euo pipefail

SUCCESS_HTML="${SUCCESS_HTML:-$ROOT_DIR/html/success_posts.html}"

add_success_post() {
  local title="$1"
  local author="$2"
  local author_url="$3"
  local post_id="$4"
  local post_url="$5"

  [[ -f "$SUCCESS_HTML" ]] || return 0

  # Escape minimal HTML
  esc() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
  }

  local row
  row="$(cat <<EOF
<tr>
  <td>$(printf '%s' "$title" | esc)</td>
  <td><a target="_blank" href="$author_url">$(printf '%s' "$author" | esc)</a></td>
  <td><a target="_blank" rel="noopener noreferrer" href="$post_url">$post_id</a></td>
</tr>
EOF
)"

  # Do not insert duplicates
  if grep -q "$post_id" "$SUCCESS_HTML"; then
    return 0
  fi

  # Insert row directly after <tbody>
  awk -v row="$row" '
    /<tbody>/ && !done {
      print;
      print row;
      done=1;
      next
    }
    { print }
  ' "$SUCCESS_HTML" > "${SUCCESS_HTML}.tmp"

  mv "${SUCCESS_HTML}.tmp" "$SUCCESS_HTML"

  # Update counter (Anzahl)
  local count
  count="$(grep -o '<tr>' "$SUCCESS_HTML" | wc -l)"

  sed -i -E "s/(Anzahl \\(unique\\): )[0-9]+/\\1$count/" "$SUCCESS_HTML"
}
