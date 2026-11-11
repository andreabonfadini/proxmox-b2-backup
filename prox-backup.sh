#!/usr/bin/env bash
# prox-backup.sh - backup di VM e container Proxmox VE su Backblaze B2 via rclone.
#
# Comandi:
#   setup  [nome]   configurazione guidata (remote rclone, bucket, cartella, guest)
#   start  [nome]   avvia il backup in background (sopravvive alla chiusura del terminale)
#   run    [nome]   esegue il backup in primo piano (per cron / systemd)
#   status [nome]   stato del lock e posizione dell'ultimo log
#
# La configurazione e' per cliente, in $CONF_DIR/<nome>.conf (un file per cliente).
set -Eeuo pipefail

PROG="$(basename "${BASH_SOURCE[0]}")"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

CONF_DIR="${PROX_BACKUP_CONF_DIR:-/etc/prox-backup/clients}"
LOG_DIR="${PROX_BACKUP_LOG_DIR:-/var/log/prox-backup}"
RUN_DIR="${PROX_BACKUP_RUN_DIR:-/run}"

# Ogni quanti secondi rclone riporta le statistiche nel log
STATS_INTERVAL="10s"

# ============================================================
# UTILITA'
# ============================================================

log() { echo "[$(date '+%F %T')] $*"; }

section() {
    echo
    echo "============================================================"
    log "$*"
    echo "============================================================"
}

die() {
    log "ERRORE: $*"
    exit 1
}

warn() { log "ATTENZIONE: $*"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "comando non trovato: $1"
}

human_size() { numfmt --to=iec-i --suffix=B "$1"; }

# Risposta interattiva in REPLY_VAL (vuoto = default).
ask() {
    local prompt="$1" default="${2-}" value
    printf '%s' "$prompt"
    [[ -n "$default" ]] && printf ' [%s]' "$default"
    printf ': '
    IFS= read -r value || true
    REPLY_VAL="${value:-$default}"
}

ask_secret() {
    local prompt="$1" value
    printf '%s' "$prompt"
    IFS= read -rs value || true
    printf '\n'
    REPLY_VAL="$value"
}

# ============================================================
# CONFIGURAZIONE CLIENTE
# ============================================================

RESOLVED_CLIENT=""

# Imposta RESOLVED_CLIENT: nome esplicito, oppure l'unico cliente configurato.
# Non stampa il nome, cosi' gli errori non finiscono dentro una sostituzione.
resolve_client() {
    local name="${1-}" c
    local -a confs=()

    if [[ -n "$name" ]]; then
        RESOLVED_CLIENT="$name"
        return 0
    fi

    shopt -s nullglob
    confs=("$CONF_DIR"/*.conf)
    shopt -u nullglob

    case ${#confs[@]} in
        0) die "nessun cliente configurato in $CONF_DIR (esegui: $PROG setup)" ;;
        1)
            RESOLVED_CLIENT="$(basename "${confs[0]}" .conf)"
            ;;
        *)
            log "Piu' clienti configurati, specificane uno:"
            for c in "${confs[@]}"; do
                echo "  - $(basename "$c" .conf)"
            done
            exit 2
            ;;
    esac
}

load_config() {
    local client="$1" conf="$CONF_DIR/$1.conf"

    [[ -f "$conf" ]] || die "config non trovata: $conf (esegui: $PROG setup $client)"

    # File di configurazione locale, di proprieta' di root.
    # shellcheck source=/dev/null
    source "$conf"

    CLIENT_NAME="$client"

    [[ -n "${RCLONE_REMOTE:-}" ]] || die "RCLONE_REMOTE non impostato in $conf"
    [[ "$RCLONE_REMOTE" == *:*/* ]] || die "RCLONE_REMOTE non valido in $conf (atteso: remote:bucket/cartella)"

    MODE_VM="${MODE_VM:-snapshot}"
    MODE_CT="${MODE_CT:-snapshot}"
    MODE_CT_FALLBACK="${MODE_CT_FALLBACK:-suspend}"
    COMPRESS="${COMPRESS:-zstd}"
    KEEP_COPIES="${KEEP_COPIES:-2}"
    BWLIMIT="${BWLIMIT:-}"
    VZDUMP_TMPDIR="${VZDUMP_TMPDIR:-}"

    declare -p GUESTS &>/dev/null || die "GUESTS non impostate in $conf"
    (( ${#GUESTS[@]} > 0 )) || die "GUESTS vuota in $conf"

    LOG_LATEST="$LOG_DIR/$CLIENT_NAME-latest.log"
    LOCK_FILE="$RUN_DIR/prox-backup-$CLIENT_NAME.lock"
}

# ============================================================
# GUEST (VM E CONTAINER)
# ============================================================

# Stampa "vm" o "ct"; fallisce se l'ID non esiste.
guest_type() {
    local id="$1"
    if qm config "$id" >/dev/null 2>&1; then
        echo vm
    elif pct config "$id" >/dev/null 2>&1; then
        echo ct
    else
        return 1
    fi
}

guest_name() {
    local type="$1" id="$2" out="" key="name"
    [[ "$type" == "ct" ]] && key="hostname"

    case "$type" in
        vm)  out="$(qm config "$id" 2>/dev/null || true)" ;;
        ct)  out="$(pct config "$id" 2>/dev/null || true)" ;;
    esac

    printf '%s\n' "$out" | sed -n "s/^${key}: //p" | head -n 1 || true
}

# Elenca i guest presenti sull'host: "<tipo> <id> <nome>"
all_guests() {
    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        printf 'vm %s %s\n' "$id" "$(guest_name vm "$id")"
    done < <(qm list 2>/dev/null | awk 'NR>1 && NF {print $1}')

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        printf 'ct %s %s\n' "$id" "$(guest_name ct "$id")"
    done < <(pct list 2>/dev/null | awk 'NR>1 && NF {print $1}')
}

# Estensione del file remoto in base al tipo e alla compressione.
guest_suffix() {
    local type="$1" ext="vma"
    [[ "$type" == "ct" ]] && ext="tar"

    case "$COMPRESS" in
        zstd)    printf '.%s.zst' "$ext" ;;
        gzip|1)  printf '.%s.gz' "$ext" ;;
        lzo)     printf '.%s.lzo' "$ext" ;;
        *)       printf '.%s' "$ext" ;;
    esac
}

# ============================================================
# BACKBLAZE B2
# ============================================================

check_remote() {
    section "VERIFICA CONNESSIONE BACKBLAZE B2"

    log "Destinazione: $RCLONE_REMOTE"

    # Idempotente: verifica le credenziali e crea la cartella se manca.
    rclone mkdir "$RCLONE_REMOTE" \
        || die "impossibile creare la cartella remota: $RCLONE_REMOTE"

    rclone lsf "$RCLONE_REMOTE" >/dev/null \
        || die "cartella remota non leggibile: $RCLONE_REMOTE"

    log "OK: bucket e cartella accessibili."
}

verify_remote_backup() {
    local remote_file="$1" size
    local full_path="$RCLONE_REMOTE/$remote_file"

    log "Verifica file remoto: $remote_file"

    if ! size="$(rclone size "$full_path" --json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])' 2>/dev/null)"; then
        warn "impossibile verificare il file remoto."
        return 1
    fi

    if ! [[ "$size" =~ ^[0-9]+$ ]] || (( size == 0 )); then
        warn "dimensione remota non valida."
        return 1
    fi

    VERIFIED_SIZE="$size"
    log "OK: file presente su Backblaze ($(human_size "$size"))."

    # Verifica esistenza e dimensione, non l'integrita' del contenuto.
    return 0
}

# Mantiene le ultime $KEEP_COPIES copie del guest (inclusa quella appena caricata).
prune_guest() {
    local type="$1" id="$2" current="$3"
    local prefix="${type}${id}-"
    local -a files=()
    local f kept=0 to_keep

    to_keep=$(( KEEP_COPIES > 1 ? KEEP_COPIES - 1 : 0 ))

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ "$f" == "$prefix"* ]] || continue
        [[ "$f" == "$current" ]] && continue
        files+=("$f")
    done < <(rclone lsf "$RCLONE_REMOTE" --files-only 2>/dev/null | sort -r)

    if (( ${#files[@]} == 0 )); then
        log "Nessun backup precedente da eliminare."
        return 0
    fi

    for f in "${files[@]}"; do
        if (( kept < to_keep )); then
            kept=$((kept + 1))
            log "Conservato: $f"
            continue
        fi

        log "Eliminazione: $f"
        rclone deletefile "$RCLONE_REMOTE/$f" || {
            warn "eliminazione fallita: $f"
            return 1
        }
    done

    return 0
}

# ============================================================
# BACKUP
# ============================================================

# Esegue vzdump in streaming verso rclone. $1 tipo, $2 id, $3 modalita', $4 path remoto
stream_guest() {
    local type="$1" id="$2" mode="$3" remote_path="$4"
    local -a rclone_args=(rcat "$remote_path"
        --stats "$STATS_INTERVAL"
        --stats-log-level NOTICE
        --log-level NOTICE)
    local -a vzdump_args=("$id" --mode "$mode" --compress "$COMPRESS" --stdout)

    [[ -n "$BWLIMIT" ]] && rclone_args+=(--bwlimit "$BWLIMIT")
    [[ -n "$VZDUMP_TMPDIR" && "$type" == "ct" && "$mode" != "stop" ]] && vzdump_args+=(--tmpdir "$VZDUMP_TMPDIR")

    # Lo streaming evita di occupare spazio locale per un file temporaneo.
    vzdump "${vzdump_args[@]}" | rclone "${rclone_args[@]}"
}

backup_guest() {
    local id="$1"
    local type name mode remote_file remote_path start_time duration

    if ! type="$(guest_type "$id")"; then
        warn "guest $id non trovato su questo nodo."
        return 1
    fi

    name="$(guest_name "$type" "$id")"
    name="${name:-sconosciuto}"

    if [[ "$type" == "vm" ]]; then
        mode="$MODE_VM"
    else
        mode="$MODE_CT"
    fi

    remote_file="${type}${id}-$(date +%F)$(guest_suffix "$type")"
    remote_path="$RCLONE_REMOTE/$remote_file"

    section "BACKUP ${type^^} $id ($name) [modalita' $mode, compressione ${COMPRESS:-nessuna}]"
    log "Destinazione: $remote_path"

    start_time=$SECONDS

    if ! stream_guest "$type" "$id" "$mode" "$remote_path"; then
        # I CT su storage senza snapshot non reggono la modalita' snapshot:
        # un solo tentativo con la modalita' di ripiego.
        if [[ "$type" == "ct" && "$mode" != "$MODE_CT_FALLBACK" ]]; then
            warn "backup CT $id fallito in modalita' $mode, riprovo in modalita' $MODE_CT_FALLBACK"
            mode="$MODE_CT_FALLBACK"
            if ! stream_guest "$type" "$id" "$mode" "$remote_path"; then
                warn "backup/trasferimento CT $id fallito."
                return 1
            fi
        else
            warn "backup/trasferimento $type $id fallito."
            return 1
        fi
    fi

    log "Streaming terminato senza errori."

    if ! verify_remote_backup "$remote_file"; then
        warn "verifica remota non superata: i vecchi backup non saranno eliminati."
        return 1
    fi

    duration=$((SECONDS - start_time))
    log "Durata: $((duration / 60))m $((duration % 60))s - dati: $(human_size "$VERIFIED_SIZE")"

    SUCCESS_GUESTS+=("$id")
    TOTAL_BYTES=$((TOTAL_BYTES + VERIFIED_SIZE))

    # Retention solo dopo upload verificato.
    prune_guest "$type" "$id" "$remote_file" \
        || warn "backup riuscito, ma pulizia remota incompleta."

    log "SUCCESSO: $type $id salvato su Backblaze B2."
    return 0
}

# ============================================================
# COMANDI
# ============================================================

cmd_run() {
    local client="$1"

    load_config "$client"

    section "AVVIO BACKUP PROXMOX -> BACKBLAZE B2"
    log "Cliente: $CLIENT_NAME"
    log "Host: $(hostname)"
    log "Guest: ${GUESTS[*]}"

    (( EUID == 0 )) || warn "esecuzione non come root: vzdump potrebbe fallire."

    require_cmd qm
    require_cmd pct
    require_cmd vzdump
    require_cmd rclone
    require_cmd python3
    require_cmd numfmt
    require_cmd flock

    mkdir -p "$RUN_DIR"

    # Evita esecuzioni contemporanee per lo stesso cliente.
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "backup gia' in esecuzione per il cliente $CLIENT_NAME"

    check_remote

    SUCCESS_GUESTS=()
    FAILED_GUESTS=()
    TOTAL_BYTES=0
    VERIFIED_SIZE=0

    local start=$SECONDS id

    for id in "${GUESTS[@]}"; do
        backup_guest "$id" || FAILED_GUESTS+=("$id")
    done

    section "RIEPILOGO FINALE"

    log "Guest richiesti: ${#GUESTS[@]}"
    log "Riusciti: ${#SUCCESS_GUESTS[@]}"
    log "Falliti: ${#FAILED_GUESTS[@]}"
    log "Totale verificato su B2: $(human_size "$TOTAL_BYTES")"
    log "Durata totale: $(((SECONDS - start) / 60))m $(((SECONDS - start) % 60))s"

    (( ${#SUCCESS_GUESTS[@]} > 0 )) && log "Backup riusciti: ${SUCCESS_GUESTS[*]}"

    if (( ${#FAILED_GUESTS[@]} > 0 )); then
        log "Backup falliti: ${FAILED_GUESTS[*]}"
        log "STATO FINALE: COMPLETATO CON ERRORI"
        exit 1
    fi

    log "STATO FINALE: COMPLETATO CON SUCCESSO"
    exit 0
}

cmd_start() {
    local client="$1" log_file

    load_config "$client"
    require_cmd setsid

    mkdir -p "$LOG_DIR" "$RUN_DIR"

    # Rifiuta l'avvio se un backup e' gia' in corso.
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "backup gia' in esecuzione per il cliente $CLIENT_NAME"
    exec 9>&-

    log_file="$LOG_DIR/$CLIENT_NAME-$(date +%F_%H%M%S).log"

    # setsid: il processo non e' piu' legato al terminale, la chiusura
    # della finestra o del terminale SSH non lo interrompe.
    setsid "$SELF" run "$CLIENT_NAME" >"$log_file" 2>&1 </dev/null &

    ln -sfn "$log_file" "$LOG_LATEST"

    echo
    log "Backup avviato in background per il cliente $CLIENT_NAME."
    log "Log: $log_file"
    log "Stato: $PROG status $CLIENT_NAME"

    # Mostra l'avvio: intercetta subito gli errori di configurazione.
    sleep 2
    echo
    sed -n '1,20p' "$log_file"
}

cmd_status() {
    local client="$1" lock_state="libero" log_file

    load_config "$client"

    exec 9>"$LOCK_FILE"
    flock -n 9 || lock_state="OCCUPATO (backup in esecuzione)"
    exec 9>&-

    echo "Cliente:       $CLIENT_NAME"
    echo "Destinazione:  $RCLONE_REMOTE"
    echo "Guest:         ${GUESTS[*]}"
    echo "Copie tenute:  $KEEP_COPIES"
    echo "Lock:          $lock_state"

    if [[ -f "$LOG_LATEST" ]]; then
        log_file="$(readlink -f "$LOG_LATEST")"
        echo "Ultimo log:    $log_file"
        echo
        tail -n 15 "$log_file"
    else
        echo "Ultimo log:    nessun log in $LOG_DIR"
    fi
}

cmd_setup() {
    local client="${1-}" key_id key_app remote_name dirs bucket prefix remote probe guest_lines
    local sel ok n gid keep bwlimit guests_str g
    local -a selection=() nums=()

    require_cmd rclone
    require_cmd python3

    section "CONFIGURAZIONE GUIDATA"

    # --- cliente ---------------------------------------------------------
    while :; do
        ask "Nome cliente (es. acme)" "$client"
        client="${REPLY_VAL// /-}"
        if [[ -z "$client" ]]; then
            echo "Il nome e' obbligatorio."
            continue
        fi
        if [[ ! "$client" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            echo "Usa solo lettere, numeri, punto, trattino e underscore."
            continue
        fi
        break
    done

    mkdir -p "$CONF_DIR"
    echo "Config: $CONF_DIR/$client.conf"
    echo

    # --- credenziali B2 --------------------------------------------------
    echo "-- Credenziali Backblaze B2 (Application Key)"
    ask "Key ID"
    key_id="$REPLY_VAL"
    [[ -n "$key_id" ]] || die "Key ID obbligatorio."
    ask_secret "Application Key: "
    key_app="$REPLY_VAL"
    [[ -n "$key_app" ]] || die "Application Key obbligatoria."

    ask "Nome remote rclone" "b2-$client"
    remote_name="${REPLY_VAL// /-}"

    if [[ $'\n'$(rclone listremotes 2>/dev/null) == *$'\n'"$remote_name:"* ]]; then
        log "Remote esistente, aggiorno le credenziali..."
        rclone config update "$remote_name" account "$key_id" key "$key_app" hard_delete true --non-interactive >/dev/null
    else
        log "Creo il remote rclone..."
        # hard_delete: senza, rclone nasconde le versioni invece di eliminarle
        # e lo spazio occupato su B2 non torna mai libero.
        rclone config create "$remote_name" b2 account "$key_id" key "$key_app" hard_delete true --non-interactive >/dev/null
    fi

    log "Verifico le credenziali..."
    dirs="$(rclone lsf "$remote_name:" --dirs-only 2>/dev/null)" \
        || die "credenziali non valide o account non raggiungibile."

    # --- bucket ----------------------------------------------------------
    echo
    echo "-- Bucket disponibili:"
    if [[ -z "$dirs" ]]; then
        echo "   (nessun bucket visibile)"
    else
        printf '%s\n' "$dirs" | sed 's#/$##' | awk '{printf "   %2d) %s\n", NR, $0}'
    fi
    echo

    while :; do
        ask "Bucket (numero esistente oppure nome nuovo)"
        bucket="$REPLY_VAL"

        if [[ "$bucket" =~ ^[0-9]+$ ]]; then
            bucket="$(printf '%s\n' "$dirs" | sed 's#/$##' | sed -n "${bucket}p")"
            [[ -n "$bucket" ]] || { echo "Numero non valido."; continue; }
        fi

        [[ -n "$bucket" ]] || { echo "Il bucket e' obbligatorio."; continue; }

        if [[ $'\n'"$dirs" != *$'\n'"$bucket/"* ]]; then
            log "Il bucket $bucket non esiste, lo creo."
            rclone mkdir "$remote_name:$bucket" || { echo "Creazione fallita."; continue; }
        fi
        break
    done

    # --- cartella --------------------------------------------------------
    ask "Cartella nel bucket" "proxmox-$client"
    prefix="${REPLY_VAL#/}"
    prefix="${prefix%/}"
    [[ -n "$prefix" ]] || die "La cartella e' obbligatoria."

    remote="$remote_name:$bucket/$prefix"
    log "Preparo $remote ..."
    rclone mkdir "$remote" || die "impossibile creare la cartella remota."

    # --- prova di scrittura ----------------------------------------------
    probe=".prox-backup-probe-$$"
    if echo ok | rclone rcat "$remote/$probe" && rclone deletefile "$remote/$probe"; then
        log "OK: scrittura e cancellazione funzionano."
    else
        die "non riesco a scrivere/cancellare in $remote: controlla i permessi della chiave."
    fi

    # --- selezione guest -------------------------------------------------
    section "SELEZIONE GUEST"

    if ! command -v qm >/dev/null 2>&1 && ! command -v pct >/dev/null 2>&1; then
        die "qm/pct non trovati: esegui setup su un nodo Proxmox VE."
    fi

    guest_lines="$(all_guests)"
    if [[ -z "$guest_lines" ]]; then
        die "nessuna VM o container trovato su questo nodo."
    fi

    echo "Guest presenti:"
    printf '%s\n' "$guest_lines" | awk '{printf "   %2d) %-2s %-6s %s\n", NR, $1, $2, $3}'
    echo
    echo "Indica i numeri separati da virgola, oppure 'all'."

    while :; do
        ask "Selezione"
        sel="$REPLY_VAL"

        if [[ "$sel" == "all" ]]; then
            mapfile -t selection < <(printf '%s\n' "$guest_lines" | awk '{print $2}')
            break
        fi

        selection=()
        ok=1
        IFS=', ' read -ra nums <<< "$sel"
        for n in "${nums[@]}"; do
            [[ -z "$n" ]] && continue
            if [[ ! "$n" =~ ^[0-9]+$ ]]; then ok=0; break; fi
            gid="$(printf '%s\n' "$guest_lines" | awk -v n="$n" 'NR==n {print $2}')"
            if [[ -z "$gid" ]]; then ok=0; break; fi
            selection+=("$gid")
        done

        if (( ok == 0 )) || (( ${#selection[@]} == 0 )); then
            echo "Selezione non valida."
            continue
        fi
        break
    done

    # --- opzioni ---------------------------------------------------------
    echo
    ask "Copie da tenere per guest" "2"
    keep="$REPLY_VAL"
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=2

    ask "Limite banda di upload (es. 8M, vuoto = nessuno)" ""
    bwlimit="$REPLY_VAL"

    # --- scrittura config ------------------------------------------------
    for g in "${selection[@]}"; do
        guests_str+="$g "
    done

    umask 077
    cat > "$CONF_DIR/$client.conf" <<EOF
# Configurazione prox-backup.sh - cliente $client
# Generato il $(date '+%F %T'). Contiene solo riferimenti, nessuna credenziale.

RCLONE_REMOTE="$remote"

GUESTS=(${guests_str% })

# snapshot | suspend | stop
MODE_VM="snapshot"
MODE_CT="snapshot"
# usata per i CT quando lo storage non supporta gli snapshot
MODE_CT_FALLBACK="suspend"

COMPRESS="zstd"
KEEP_COPIES="$keep"
BWLIMIT="$bwlimit"
# solo CT in modalita' suspend: cartella temporanea locale
VZDUMP_TMPDIR=""
EOF
    umask 022
    chmod 600 "$CONF_DIR/$client.conf"

    section "CONFIGURAZIONE COMPLETATA"
    log "Config: $CONF_DIR/$client.conf"
    log "Destinazione: $remote"
    log "Guest: ${selection[*]}"
    echo
    echo "Avvio manuale:  $PROG start $client"
    echo "In cron:        0 3 * * * $SELF run $client"
}

usage() {
    cat <<EOF
$PROG - backup di VM e container Proxmox VE su Backblaze B2

Uso: $PROG <comando> [cliente]

  setup [cliente]   configurazione guidata: remote rclone, bucket, cartella,
                    selezione delle VM e dei container da salvare
  start [cliente]   avvia il backup in background (chiudere il terminale non
                    interrompe il backup)
  run   [cliente]   esegue il backup in primo piano (per cron o systemd)
  status [cliente]  stato del lock e ultimo log

Variabili d'ambiente:
  PROX_BACKUP_CONF_DIR  default $CONF_DIR
  PROX_BACKUP_LOG_DIR   default $LOG_DIR
  PROX_BACKUP_RUN_DIR   default $RUN_DIR
EOF
}

# ============================================================
# MAIN
# ============================================================

case "${1-}" in
    setup)   shift; cmd_setup "${1-}" ;;
    start)   shift; resolve_client "${1-}"; cmd_start "$RESOLVED_CLIENT" ;;
    run)     shift; resolve_client "${1-}"; cmd_run "$RESOLVED_CLIENT" ;;
    status)  shift; resolve_client "${1-}"; cmd_status "$RESOLVED_CLIENT" ;;
    help|-h|--help|"") usage ;;
    *)
        log "comando sconosciuto: $1"
        usage
        exit 2
        ;;
esac
