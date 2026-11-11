#!/usr/bin/env bash
# Smoke test di prox-backup.sh senza Proxmox e senza Backblaze.
# Usa stub di qm/pct/vzdump e un remote rclone di tipo local come finto B2.
#
#   bash test/smoke.sh
set -Eeuo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/prox-backup.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Il remote rclone di test e' di tipo local: in rclone 1.76 il parametro
# "root" non viene applicato, quindi ci si sposta in $T e si usa $T come radice.
cd "$T"

BIN="$T/bin"
CONF="$T/conf"
LOG="$T/log"
RUN="$T/run"
DST="$T/acme-bucket/proxmox-acme"
mkdir -p "$BIN" "$CONF" "$LOG" "$RUN"

export RCLONE_CONFIG="$T/rclone.conf"
export PROX_BACKUP_CONF_DIR="$CONF"
export PROX_BACKUP_LOG_DIR="$LOG"
export PROX_BACKUP_RUN_DIR="$RUN"
export PATH="$BIN:$PATH"

pass=0
failn=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
ko()   { printf '  FAIL %s\n' "$1"; failn=$((failn + 1)); }
assert_file()     { [[ -f "$1" ]] && ok "$2" || ko "$2 (manca $1)"; }
assert_absent()   { [[ ! -e "$1" ]] && ok "$2" || ko "$2 (presente: $1)"; }
assert_contains() { grep -qF -- "$2" "$1" 2>/dev/null && ok "$3" || ko "$3"; }
assert_size()     { [[ "$(stat -c %s "$1" 2>/dev/null)" == "$2" ]] && ok "$3" || ko "$3"; }

# --- stub Proxmox -----------------------------------------------------------
cat > "$BIN/qm" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  list)
    printf '      VMID NAME                 STATUS\n'
    printf '       100 web                  running\n'
    printf '       102 db                   stopped\n'
    ;;
  config)
    case "$2" in
      100) echo "name: web" ;;
      102) echo "name: db" ;;
      *)   echo "configuration file does not exist" >&2; exit 2 ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOS

cat > "$BIN/pct" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  list)
    printf 'VMID       Status     Lock         Name\n'
    printf '104        running                 turnkey-files\n'
    ;;
  config)
    case "$2" in
      104) echo "hostname: turnkey-files" ;;
      *)   echo "configuration file does not exist" >&2; exit 2 ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOS

# vzdump: 8 KiB deterministici su stdout; fallisce sui CT in modalita' snapshot.
cat > "$BIN/vzdump" <<'EOS'
#!/usr/bin/env bash
id="$1"; shift
mode="snapshot"
while (( $# )); do
  case "$1" in
    --mode)      mode="$2"; shift 2 ;;
    --compress)  shift 2 ;;
    *)           shift ;;
  esac
done
if [[ "$id" == 104 && "$mode" == snapshot ]]; then
  echo "ERROR: snapshot mode not supported by storage 'local'" >&2
  exit 1
fi
[[ -n "${PROX_TEST_SLOW:-}" ]] && sleep 2
echo "INFO: creating archive for guest $id (mode $mode)" >&2
head -c 8192 /dev/zero
EOS

chmod +x "$BIN/qm" "$BIN/pct" "$BIN/vzdump"

# --- finto B2 (remote local) ------------------------------------------------
if ! rclone config create testlocal local --non-interactive >/dev/null 2>&1; then
  echo "FATAL: impossibile creare il remote rclone di test"
  exit 1
fi

echo "== setup interattivo =="
printf '%s\n' acme ACC-KEY-ID-TEST APP-KEY-TEST testlocal acme-bucket proxmox-acme all 2 "" \
  | bash "$SCRIPT" setup > "$T/setup.out" 2>&1 \
  || { echo "setup fallito:"; cat "$T/setup.out"; exit 1; }

assert_file "$CONF/acme.conf" "config cliente generata"
assert_contains "$CONF/acme.conf" 'RCLONE_REMOTE="testlocal:acme-bucket/proxmox-acme"' "RCLONE_REMOTE scritto"
assert_contains "$CONF/acme.conf" "GUESTS=(100 102 104)" "guest selezionati"
[[ "$(stat -c %a "$CONF/acme.conf")" == "600" ]] && ok "config con permessi 600" || ko "permessi config"
[[ -d "$DST" ]] && ok "cartella remota creata" || ko "cartella remota"
shopt -s nullglob
probes=("$DST"/.prox-backup-probe-*)
shopt -u nullglob
(( ${#probes[@]} == 0 )) && ok "file di prova rimosso" || ko "file di prova rimasto"

echo "== backup completo =="
DATE="$(date +%F)"
bash "$SCRIPT" run acme > "$T/run1.log" 2>&1 || { echo "run fallito:"; tail -40 "$T/run1.log"; exit 1; }

assert_file     "$DST/vm100-$DATE.vma.zst" "VM 100 caricata (.vma.zst)"
assert_size     "$DST/vm100-$DATE.vma.zst" 8192 "VM 100 dimensione corretta"
assert_file     "$DST/vm102-$DATE.vma.zst" "VM 102 caricata"
assert_file     "$DST/ct104-$DATE.tar.zst" "CT 104 caricato (.tar.zst)"
assert_size     "$DST/ct104-$DATE.tar.zst" 8192 "CT 104 dimensione corretta"
assert_contains "$T/run1.log" "riprovo in modalita' suspend" "fallback snapshot->suspend sul CT"
assert_contains "$T/run1.log" "STATO FINALE: COMPLETATO CON SUCCESSO" "esito finale"

echo "== retention (KEEP_COPIES=2) =="
for d in 2020-01-01 2020-01-02 2020-01-03; do
  echo old > "$DST/vm100-$d.vma.zst"
done
bash "$SCRIPT" run acme > "$T/run2.log" 2>&1 || true

assert_file   "$DST/vm100-2020-01-03.vma.zst" "conservata la copia piu' recente"
assert_absent "$DST/vm100-2020-01-02.vma.zst"  "eliminata la copia oltre il limite"
assert_absent "$DST/vm100-2020-01-01.vma.zst"  "eliminata la copia piu' vecchia"
assert_absent "$DST/vm102-2020-01-01.vma.zst"  "retention non tocca altri guest"

echo "== avvio asincrono =="
# vzdump rallentato: il backup e' ancora in corso quando start ritorna.
PROX_TEST_SLOW=1 bash "$SCRIPT" start acme > "$T/start.out" 2>&1 \
  || { echo "start fallito:"; cat "$T/start.out"; exit 1; }
assert_contains "$T/start.out" "avviato in background" "messaggio di avvio"

pid="$(pgrep -f "prox-backup.sh run acme" | head -n 1 || true)"
if [[ -n "$pid" ]]; then
  ok "processo di backup attivo dopo la chiusura del comando"
  sid_child="$(ps -o sid= -p "$pid" | tr -d ' ')"
  sid_self="$(ps -o sid= -p $$ | tr -d ' ')"
  [[ -n "$sid_child" && "$sid_child" != "$sid_self" ]] \
    && ok "sessione separata (setsid: sopravvive al terminale)" \
    || ko "sessione non separata (sid $sid_child)"
  ppid_child="$(ps -o ppid= -p "$pid" | tr -d ' ')"
  [[ "$ppid_child" == "1" ]] && ok "riparentato a init" || ko "ppid=$ppid_child"
else
  ko "processo di backup non trovato dopo start"
fi

for _ in $(seq 1 60); do
  pgrep -f "prox-backup.sh run acme" >/dev/null || break
  sleep 1
done

logfile="$(ls -t "$LOG"/acme-*.log 2>/dev/null | sed -n 1p)"
assert_file "$logfile" "log di background creato"
assert_contains "$logfile" "STATO FINALE" "backup in background completato"

echo "== status =="
bash "$SCRIPT" status acme > "$T/status.out" 2>&1 || true
assert_contains "$T/status.out" "Lock:          libero" "lock rilasciato dopo il backup"
assert_contains "$T/status.out" "Copie tenute:  2" "status mostra la retention"

echo "== guest inesistente =="
sed 's/^GUESTS=.*/GUESTS=(999)/' "$CONF/acme.conf" > "$CONF/rotto.conf"
if bash "$SCRIPT" run rotto > "$T/run3.log" 2>&1; then
  ko "guest inesistente: exit 0 inatteso"
else
  ok "guest inesistente: esce con errore"
fi
assert_contains "$T/run3.log" "guest 999 non trovato" "messaggio per guest inesistente"

echo "== dispatch cliente =="
# Due clienti configurati e nessun nome: deve rifiutare e dire quali sono.
if bash "$SCRIPT" status > "$T/multi.out" 2>&1; then
  ko "piu' clienti senza nome: exit 0 inatteso"
else
  [[ $? -eq 2 ]] && ok "piu' clienti senza nome: exit 2" || ko "exit code inatteso"
fi
assert_contains "$T/multi.out" "- acme" "elenca i clienti disponibili"

# Nessuna configurazione: errore su una sola riga, non spezzato.
if PROX_BACKUP_CONF_DIR="$T/vuoto" bash "$SCRIPT" status > "$T/noconf.out" 2>&1; then
  ko "nessuna config: exit 0 inatteso"
else
  ok "nessuna config: esce con errore"
fi
[[ "$(grep -c 'nessun cliente configurato' "$T/noconf.out")" == "1" ]] \
  && ok "nessuna config: messaggio non duplicato" || ko "messaggio errore sporco"
[[ "$(grep -c 'ERRORE' "$T/noconf.out")" == "1" ]] \
  && ok "nessuna config: un solo messaggio di errore" || ko "messaggio errore sporco"

echo
if (( failn > 0 )); then
  echo "FALLITI: $failn, passati: $pass"
  exit 1
fi
echo "TUTTI I TEST PASSATI: $pass"
