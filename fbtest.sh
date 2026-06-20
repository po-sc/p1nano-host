#!/bin/bash
# Тест ОБРАТНОЙ СВЯЗИ: внешнее изменение громкости macOS должно двигать мотор фейдера.
cd "$(dirname "$0")"
pkill -9 -x devicesim 2>/dev/null || true; pkill -9 -x host 2>/dev/null || true; sleep 2
swiftc devicesim.swift -o devicesim 2>&1 | grep -i "error:" && exit 1 || true
swiftc host.swift -o host 2>&1 | grep -i "error:" && exit 1 || true

V_ORIG=$(osascript -e 'output volume of (get volume settings)')
cleanup(){ kill $SIM $HOST 2>/dev/null; osascript -e "set volume output volume $V_ORIG"; }
trap cleanup EXIT

./devicesim nofader > /tmp/sim.log 2>&1 & SIM=$!
sleep 1
osascript -e 'set volume output volume 50'
DBG=1 ./host "P1Sim" > /tmp/host.log 2>&1 & HOST=$!
sleep 2   # дать встать онлайн

echo "=== внешне меняю громкость (как с клавиатуры): 20, 80, 35 ==="
osascript -e 'set volume output volume 20'; sleep 0.6
osascript -e 'set volume output volume 80'; sleep 0.6
osascript -e 'set volume output volume 35'; sleep 0.6

echo "--- команды мотора, которые хост отправил на фейдер ---"
grep "МОТОР" /tmp/sim.log | tail -10
echo
if grep -qE "МОТОР позиция (19|20|21)" /tmp/sim.log && grep -qE "МОТОР позиция (79|80|81)" /tmp/sim.log && grep -qE "МОТОР позиция (34|35|36)" /tmp/sim.log; then
  echo "✅ ОБРАТНАЯ СВЯЗЬ РАБОТАЕТ: внешнее изменение громкости двигает мотор фейдера (20, 80, 35)"
else
  echo "❌ обратная связь не сработала — смотри /tmp/sim.log"
fi
