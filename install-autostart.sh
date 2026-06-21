#!/bin/bash
# Ставит хост в автозапуск (LaunchAgent): поднимается при логине, сам держится живым,
# сам подключается к iCON когда его включат (через MIDINotify). Лог: /tmp/p1nano-host.log
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"
PLIST="$HOME/Library/LaunchAgents/com.poscripty.p1nano-host.plist"
LABEL="com.poscripty.p1nano-host"
PORT="${1:-Порт 3}"

echo "=== сборка ==="
swiftc host.swift -o host 2>&1 | grep -i "error:" && { echo "ОШИБКА сборки"; exit 1; } || true
echo "ок: $DIR/host"

# снять прежний автозапуск, если был
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DIR/host</string>
        <string>$PORT</string>
    </array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>       <true/>
    <key>StandardOutPath</key>  <string>/tmp/p1nano-host.log</string>
    <key>StandardErrorPath</key><string>/tmp/p1nano-host.log</string>
    <key>ProcessType</key>      <string>Interactive</string>
</dict>
</plist>
EOF
echo "plist: $PLIST"

launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
echo "✅ автозапуск установлен и запущен. Лог: /tmp/p1nano-host.log"
echo
echo "ВАЖНО про права: медиа-клавиши (Play/треки/яркость) требуют разрешения"
echo "  System Settings → Privacy & Security → Accessibility → добавить:"
echo "  $DIR/host"
echo "Громкость/фейдер/LCD/Mute работают и без этого."
