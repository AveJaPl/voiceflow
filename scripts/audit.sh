#!/usr/bin/env bash
# Audyt kondycji voiceflow: wycieki pamieci, osierocone procesy, pliki, bledy.
#
# Uzycie: bash scripts/audit.sh [liczba-cykli]     (domyslnie 12)
#
# Nagrywa cisze, wiec transkrypcja wychodzi pusta i nic nie zostanie wklejone
# do aktywnego okna. Mozna spokojnie uruchamiac przy pracy.
set -uo pipefail

VF="${HOME}/.local/bin/voiceflow"
RUNDIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/voiceflow"
CYCLES="${1:-12}"
UNIT=voiceflow.service

# Liczy procesy okna podgladu bez lapania wlasnego polecenia w pgrep -f, co
# przy dopasowaniu do pelnej linii komend jest bardzo latwe i daje falszywy alarm.
policz_okna() {
  local liczba=0 pid cmd
  for pid in $(pgrep -x python3 2>/dev/null || true); do
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmd" in *voiceflow-overlay.py*) liczba=$((liczba + 1)) ;; esac
  done
  printf '%d' "$liczba"
}

demon_pid() { systemctl --user show -p MainPID --value "$UNIT"; }

pomiar() {
  local etykieta="$1" pid rss vram watki fd nagrania
  pid=$(demon_pid)
  rss=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
  watki=$(awk '/^Threads/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
  fd=$(ls "/proc/$pid/fd" 2>/dev/null | wc -l)
  vram=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null \
         | awk -F', ' -v p="$pid" '$1==p{gsub(/ MiB/,"",$2); print $2}')
  [ -z "$vram" ] && vram="-"
  nagrania=$(ls "$RUNDIR"/recording-*.wav 2>/dev/null | wc -l)
  printf '  %-14s RSS=%8s kB  VRAM=%6s MiB  watki=%3s  fd=%3s  okna=%s  nagrania=%s\n' \
    "$etykieta" "$rss" "$vram" "$watki" "$fd" "$(policz_okna)" "$nagrania"
}

echo "═══════════ AUDYT voiceflow ═══════════"
START=$(systemctl --user show -p ActiveEnterTimestamp --value "$UNIT")

echo
echo "── 1. Uslugi ──"
for u in "$UNIT" ydotool.service; do
  printf '  %-20s %-10s %s\n' "$u" "$(systemctl --user is-active $u)" "$(systemctl --user is-enabled $u 2>&1)"
done
echo "  demon wystartowal: $START"

echo
echo "── 2. Stan wyjsciowy ──"
pomiar "PRZED"
PID=$(demon_pid)
RSS0=$(awk '/VmRSS/{print $2}' "/proc/$PID/status")

echo
echo "── 3. $CYCLES cykli dyktowania pod rzad ──"
for i in $(seq 1 "$CYCLES"); do
  "$VF" start >/dev/null 2>&1
  sleep 2.5
  "$VF" stop >/dev/null 2>&1
  sleep 1.8
  [ $((i % 4)) -eq 0 ] && pomiar "po cyklu $i"
done

echo
echo "── 4. Odpornosc na naduzycia ──"
printf '  %-32s %s\n' "podwojny start:" "$("$VF" start >/dev/null 2>&1; "$VF" start 2>&1 | head -1)"
printf '  %-32s %s\n' "cancel w trakcie nagrywania:" "$("$VF" cancel 2>&1 | head -1)"
printf '  %-32s %s\n' "stop bez nagrywania:" "$("$VF" stop 2>&1 | head -1)"
printf '  %-32s %s\n' "cancel bez nagrywania:" "$("$VF" cancel 2>&1 | head -1)"
sleep 2

echo
echo "── 5. Stan koncowy ──"
pomiar "PO"
RSS1=$(awk '/VmRSS/{print $2}' "/proc/$PID/status")
DELTA=$((RSS1 - RSS0))
echo "  przyrost RSS: ${DELTA} kB ($((DELTA / 1024)) MiB)"
if [ "$DELTA" -gt 204800 ]; then
  echo "  ⚠ powyzej 200 MiB — moze byc wyciek, warto zbadac"
else
  echo "  ✓ przyrost w normie"
fi

echo
echo "── 6. Osierocone procesy i pliki ──"
OKNA=$(policz_okna)
PWREC=$(pgrep -x pw-record 2>/dev/null | wc -l)
NAGR=$(ls "$RUNDIR"/recording-*.wav 2>/dev/null | wc -l)
DZIECI=$(pgrep -P "$PID" 2>/dev/null | wc -l)
printf '  okna podgladu:        %-3s %s\n' "$OKNA"  "$([ "$OKNA" -eq 0 ] && echo ✓ || echo '⚠ zostaly')"
printf '  procesy pw-record:    %-3s %s\n' "$PWREC" "$([ "$PWREC" -eq 0 ] && echo ✓ || echo '⚠ zostaly')"
printf '  nieusuniete nagrania: %-3s %s\n' "$NAGR"  "$([ "$NAGR" -eq 0 ] && echo ✓ || echo '⚠ zostaly')"
printf '  dzieci demona:        %-3s %s\n' "$DZIECI" "$([ "$DZIECI" -eq 0 ] && echo ✓ || echo '⚠ zostaly')"

echo
echo "── 7. Bledy od startu demona ──"
BLEDY=$(journalctl --user -u "$UNIT" --since "$START" --no-pager 2>/dev/null \
        | grep -icE 'ERROR|CRITICAL|Traceback' || true)
printf '  bledow: %s %s\n' "$BLEDY" "$([ "$BLEDY" -eq 0 ] && echo ✓ || echo '⚠')"
[ "$BLEDY" -gt 0 ] && journalctl --user -u "$UNIT" --since "$START" --no-pager \
  | grep -iE 'ERROR|CRITICAL|Traceback' | tail -10 | sed 's/^/    /'
echo "  restarty: $(systemctl --user show "$UNIT" -p NRestarts --value)  wynik: $(systemctl --user show "$UNIT" -p Result --value)"

echo
echo "── 8. Zasoby ──"
printf '  wagi modelu: %-8s srodowisko: %-8s kod: %s\n' \
  "$(du -sh ~/.cache/huggingface 2>/dev/null | cut -f1)" \
  "$(du -sh ~/projects/voiceflow/.venv 2>/dev/null | cut -f1)" \
  "$(du -sh --exclude=.venv ~/projects/voiceflow 2>/dev/null | cut -f1)"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader | sed 's/^/  GPU: /'
free -h | awk '/^Mem:/{print "  RAM: uzyte " $3 " z " $2 ", dostepne " $7}'

echo
echo "═══════════ KONIEC ═══════════"
