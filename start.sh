#!/bin/bash
# Запуск MCU-хоста: фейдер <-> громкость мака + HUD-плашка + Play/Pause.
# Использовать, когда P1-Nano переключён на DAW 3 (режим Ableton Live) — "мак-режим".
cd "$(dirname "$0")"
swiftc host.swift -o host 2>&1 | grep -i "error:" && { echo "ошибка сборки host.swift"; exit 1; }
pkill -9 -x host 2>/dev/null; sleep 0.5
echo "==============================================================="
echo " MCU-хост запущен."
echo "  1) Включи P1-Nano, переключи на DAW 3 (Ableton Live)."
echo "  2) Веди фейдер -> громкость мака (плавно, с HUD-плашкой)."
echo "  3) Меняй громкость с клавиатуры -> фейдер сам едет."
echo "  4) Кнопка Play (транспорт) -> Play/Pause."
echo " Стоп: Ctrl+C."
echo "==============================================================="
exec ./host "Порт 3"
