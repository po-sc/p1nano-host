#!/bin/bash
# БЕСШУМНЫЙ тест ОБРАТНОЙ СВЯЗИ: внешнее изменение громкости должно двигать мотор фейдера.
# Реальный звук НЕ трогается: "внешнее изменение" = запись в /tmp/p1nano_fakevol (DRYRUN).
cd "$(dirname "$0")"
pkill -9 -x devicesim 2>/dev/null || true; pkill -9 -x host 2>/dev/null || true; sleep 1
swiftc devicesim.swift -o devicesim 2>&1 | grep -i "error:" && exit 1 || true
swiftc host.swift -o host 2>&1 | grep -i "error:" && exit 1 || true

echo 50 > /tmp/p1nano_fakevol; rm -f /tmp/p1nano_fakemute
cleanup(){ kill $SIM $HOST 2>/dev/null; }
trap cleanup EXIT

./devicesim nofader > /tmp/sim.log 2>&1 & SIM=$!
sleep 1
DRYRUN=1 DBG=1 ./host "P1Sim" > /tmp/host.log 2>&1 & HOST=$!
sleep 2   # дать встать онлайн

echo "=== внешне меняю (виртуальную) громкость: 20, 80, 35 ==="
echo 20 > /tmp/p1nano_fakevol; sleep 0.6
echo 80 > /tmp/p1nano_fakevol; sleep 0.6
echo 35 > /tmp/p1nano_fakevol; sleep 0.6

echo "--- команды мотора, которые хост отправил на фейдер ---"
grep "МОТОР" /tmp/sim.log | tail -10
echo
if grep -qE "МОТОР позиция (19|20|21)" /tmp/sim.log && grep -qE "МОТОР позиция (79|80|81)" /tmp/sim.log && grep -qE "МОТОР позиция (34|35|36)" /tmp/sim.log; then
  echo "✅ ОБРАТНАЯ СВЯЗЬ РАБОТАЕТ: внешнее изменение громкости двигает мотор фейдера (20, 80, 35)"
else
  echo "❌ обратная связь не сработала — смотри /tmp/sim.log"
fi
