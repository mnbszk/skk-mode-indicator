#!/bin/sh
# Prints fcitx5 state, the current IM, the fcitx5 tray service and its menu
# layout (busctl JSON), one per line. The SKK input mode lives in that menu.
fcitx5-remote
fcitx5-remote -n

svc=""
for item in $(busctl --user --json=short get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher \
    org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems 2>/dev/null | grep -o '"[^"]*/StatusNotifierItem"' | tr -d '"'); do
  name=${item%%/*}
  id=$(busctl --user get-property "$name" /StatusNotifierItem org.kde.StatusNotifierItem Id 2>/dev/null)
  if [ "$id" = 's "Fcitx"' ]; then svc=$name; break; fi
done
echo "$svc"
[ -n "$svc" ] || exit 0

menu=$(busctl --user get-property "$svc" /StatusNotifierItem org.kde.StatusNotifierItem Menu | sed 's/^o "\(.*\)"$/\1/')
busctl --user call "$svc" "$menu" com.canonical.dbusmenu AboutToShow i 0 >/dev/null 2>&1
echo "$menu"
busctl --user --json=short call "$svc" "$menu" com.canonical.dbusmenu GetLayout iias 0 -- -1 0
