#!/bin/bash
# Убирает хост из автозапуска и останавливает его.
LABEL="com.poscripty.p1nano-host"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
pkill -9 -x host 2>/dev/null || true
echo "✅ автозапуск убран, хост остановлен."
