#!/bin/bash
# Локальный тест: симулятор устройства + хост, без железа.
# Проверяет, что хост корректно будит устройство, читает фейдер и крутит громкость мака.
set -e
cd "$(dirname "$0")"

# чистим прошлые экземпляры и ждём освобождения виртуальных портов
pkill -9 -x devicesim 2>/dev/null || true
pkill -9 -x host 2>/dev/null || true
sleep 2

echo "=== компиляция ==="
swiftc devicesim.swift -o devicesim 2>&1 | grep -i "error:" && { echo "ОШИБКА сборки devicesim"; exit 1; } || true
swiftc host.swift -o host 2>&1 | grep -i "error:" && { echo "ОШИБКА сборки host"; exit 1; } || true
echo "ок"

# вернём громкость в конце
V_ORIG=$(osascript -e 'output volume of (get volume settings)')
cleanup() { kill $SIM $HOST 2>/dev/null; osascript -e "set volume output volume $V_ORIG"; }
trap cleanup EXIT

echo "=== старт симулятора устройства ==="
./devicesim > /tmp/sim.log 2>&1 & SIM=$!
sleep 2

osascript -e 'set volume output volume 50'   # стартовая точка
echo "громкость до: $(osascript -e 'output volume of (get volume settings)')"

echo "=== старт хоста (против P1Sim) ==="
DBG=1 ./host "P1Sim" > /tmp/host.log 2>&1 & HOST=$!

echo "=== ждём сценарий (фейдер вниз@5с, вверх@8с) ==="
sleep 11

echo
echo "=== РЕЗУЛЬТАТ ==="
echo "--- лог симулятора ---"; tail -4 /tmp/sim.log
echo "--- лог хоста (отслеживание громкости) ---"; grep "ФЕЙДЕР" /tmp/host.log | tail -10
# проверяем по логу хоста: достигнута ли низкая (<30) и высокая (>70) громкость
MIN=$(grep -oE "громкость [0-9]+" /tmp/host.log | grep -oE "[0-9]+" | sort -n | head -1)
MAX=$(grep -oE "громкость [0-9]+" /tmp/host.log | grep -oE "[0-9]+" | sort -n | tail -1)
ONLINE=$(grep -c "ОНЛАЙН" /tmp/sim.log)
echo
echo "онлайн: $ONLINE | минимум громкости: $MIN | максимум: $MAX"
if [ "$ONLINE" -ge 1 ] && [ "${MIN:-100}" -lt 30 ] && [ "${MAX:-0}" -gt 70 ]; then
  echo "✅ ТЕСТ ПРОЙДЕН: хост разбудил устройство, прочитал фейдер и крутит громкость (диапазон $MIN..$MAX)"
else
  echo "❌ ТЕСТ НЕ ПРОЙДЕН (онлайн=$ONLINE мин=$MIN макс=$MAX). Смотри /tmp/host.log /tmp/sim.log"
fi
