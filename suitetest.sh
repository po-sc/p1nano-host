#!/bin/bash
# БЕСШУМНЫЙ тест кнопок и энкодеров (DRYRUN: ничего реального не трогается).
# Симулятор шлёт нажатия Play/prev/next/mute/app + кручение энкодеров яркости/громкости,
# проверяем, что хост распознал и выполнил (по логу + файлам-заглушкам).
cd "$(dirname "$0")"
pkill -9 -x devicesim 2>/dev/null || true; pkill -9 -x host 2>/dev/null || true; sleep 1
swiftc devicesim.swift -o devicesim 2>&1 | grep -i "error:" && exit 1 || true
swiftc host.swift -o host 2>&1 | grep -i "error:" && exit 1 || true

echo 50 > /tmp/p1nano_fakevol; rm -f /tmp/p1nano_fakemute
cleanup(){ kill $SIM $HOST 2>/dev/null; }
trap cleanup EXIT

DRYRUN=1 DBG=1 ./host "P1Sim" > /tmp/host.log 2>&1 & HOST=$!
sleep 1.5
./devicesim nofader suite > /tmp/sim.log 2>&1 & SIM=$!
sleep 7

echo "=== распознанные действия (лог хоста) ==="
grep -aE "Play/Pause|предыдущий трек|следующий трек|Mute|яркость|запуск приложения|энкодер CC" /tmp/host.log

PASS=0; total=6
grep -q "Play/Pause" /tmp/host.log && PASS=$((PASS+1)) || echo "✗ Play/Pause"
grep -q "предыдущий трек" /tmp/host.log && PASS=$((PASS+1)) || echo "✗ предыдущий трек"
grep -q "следующий трек" /tmp/host.log && PASS=$((PASS+1)) || echo "✗ следующий трек"
grep -q "Mute ON" /tmp/host.log && [ "$(cat /tmp/p1nano_fakemute 2>/dev/null)" = "1" ] && PASS=$((PASS+1)) || echo "✗ Mute"
grep -q "запуск приложения: Safari" /tmp/host.log && PASS=$((PASS+1)) || echo "✗ запуск приложения"
grep -q "энкодер CC16" /tmp/host.log && grep -q "энкодер CC23" /tmp/host.log && PASS=$((PASS+1)) || echo "✗ энкодеры"

echo
echo "виртуальная громкость после энкодера: $(cat /tmp/p1nano_fakevol), mute=$(cat /tmp/p1nano_fakemute 2>/dev/null)"
if [ "$PASS" -eq "$total" ]; then echo "✅ ВСЕ $total ПРИВЯЗОК РАБОТАЮТ"; else echo "❌ прошло $PASS/$total"; fi
