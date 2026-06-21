#!/bin/bash
# БЕСШУМНЫЙ тест: фейдер -> громкость. Реальный звук мака НЕ трогается (DRYRUN: громкость
# хранится в /tmp/p1nano_fakevol). Проверяет, что хост будит устройство, читает фейдер и
# меняет (виртуальную) громкость.
set -e
cd "$(dirname "$0")"
pkill -9 -x devicesim 2>/dev/null || true
pkill -9 -x host 2>/dev/null || true
sleep 1

echo "=== компиляция ==="
swiftc devicesim.swift -o devicesim 2>&1 | grep -i "error:" && { echo "ОШИБКА devicesim"; exit 1; } || true
swiftc host.swift -o host 2>&1 | grep -i "error:" && { echo "ОШИБКА host"; exit 1; } || true
echo ок

echo 50 > /tmp/p1nano_fakevol; rm -f /tmp/p1nano_fakemute   # стартовая (виртуальная) громкость

echo "=== старт симулятора устройства ==="
./devicesim > /tmp/sim.log 2>&1 & SIM=$!
sleep 2
echo "=== старт хоста (DRYRUN, против P1Sim) ==="
DRYRUN=1 DBG=1 ./host "P1Sim" > /tmp/host.log 2>&1 & HOST=$!
trap 'kill $SIM $HOST 2>/dev/null' EXIT

echo "=== ждём сценарий (фейдер вниз@5с, вверх@8с) ==="
sleep 11

echo; echo "=== РЕЗУЛЬТАТ ==="
echo "--- лог хоста ---"; grep "ФЕЙДЕР" /tmp/host.log | tail -6
MIN=$(grep -oE "громкость [0-9]+" /tmp/host.log | grep -oE "[0-9]+" | sort -n | head -1)
MAX=$(grep -oE "громкость [0-9]+" /tmp/host.log | grep -oE "[0-9]+" | sort -n | tail -1)
ONLINE=$(grep -c "ОНЛАЙН" /tmp/sim.log)
echo; echo "онлайн: $ONLINE | минимум: $MIN | максимум: $MAX (виртуальные, реальный звук не тронут)"
if [ "$ONLINE" -ge 1 ] && [ "${MIN:-100}" -lt 30 ] && [ "${MAX:-0}" -gt 70 ]; then
  echo "✅ ТЕСТ ПРОЙДЕН: фейдер читается, громкость крутится (диапазон $MIN..$MAX)"
else
  echo "❌ НЕ ПРОЙДЕН (онлайн=$ONLINE мин=$MIN макс=$MAX)"
fi
