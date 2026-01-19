#!/bin/bash
set -eo pipefail

LOG="/tmp/5g_monitor_api.log"
LAST="/tmp/5g_monitor_api_last_response.txt"

log() {
  # log só quando chamado (falhas)
  echo "[$(date '+%F %T')] $*" >> "$LOG"
}

# Suporta 2 formatos:
# 1) Zabbix (External check): script[ID,INSTANCE,HOST,DATA,KEY]  -> chega como 5 args separados
# 2) CLI manual: 'ID,INSTANCE,HOST,DATA,KEY'                    -> chega como 1 arg CSV
if [[ $# -ge 5 ]]; then
  ID="$1"
  INSTANCE="$2"
  HOST="$3"
  DATA="$4"
  KEY="$5"
else
  ARG="${1:-}"
  IFS=',' read -r ID INSTANCE HOST DATA KEY <<< "$ARG"
fi

if [[ -z "${ID:-}" || -z "${INSTANCE:-}" || -z "${HOST:-}" || -z "${DATA:-}" || -z "${KEY:-}" ]]; then
  log "PARAMETROS_INVALIDOS: args='$*' (esperado: ID INSTANCE HOST DATA KEY) ou 'ID,INSTANCE,HOST,DATA,KEY'"
  echo 0
  exit 0
fi

URL="https://${HOST}/${INSTANCE}/main-getData.php"

CURL_OPTS=(
  -4 -s -k
  --connect-timeout 5
  --max-time 10
  --retry 2
  --retry-delay 0
  --retry-max-time 10
)

PAYLOAD="ip_auth_key=${KEY}&m=hist&t=1&intr=0.1&group=1&intr_offs=0&json={\"${DATA}\":[${ID}]}"

raw="$(curl "${CURL_OPTS[@]}" "$URL" --data-raw "$PAYLOAD" 2>/dev/null || true)"

# Se curl não trouxe nada, loga e sai
if [[ -z "$raw" ]]; then
  log "CURL_VAZIO: url='$URL' payload='$PAYLOAD'"
  echo 0
  exit 0
fi

line="$(printf "%s" "$raw" | grep -Eo '\$[cC]_=\{.*\};' | head -n 1 || true)"

# Fallback: tenta em linha única
if [[ -z "$line" ]]; then
  line="$(printf "%s" "$raw" | tr '\n' ' ' | grep -Eo '\$[cC]_=\{.*\};' | head -n 1 || true)"
fi

if [[ -z "$line" ]]; then
  log "NAO_ACHEI_BLOCO_\$C_: url='$URL' id='$ID' data='$DATA' instance='$INSTANCE' host='$HOST'"
  log "DICA: ver '$LAST' para a ultima resposta completa."
  printf "%s" "$raw" > "$LAST"
  echo 0
  exit 0
fi

# Parse do bloco e retorno do valor
python3 - "$ID" "$DATA" "$line" <<'PY'
import sys, re, json

cell_id = sys.argv[1]
metric  = sys.argv[2]
line    = sys.argv[3]

m = re.search(r'=\s*(\{.*\})\s*;', line, re.S)
if not m:
    print(0)
    sys.exit(0)

try:
    data = json.loads(m.group(1))
    arr = data.get(metric, {}).get(cell_id)
    if not isinstance(arr, list) or not arr:
        print(0)
        sys.exit(0)

    # Se o último for flag 0/1, pega o penúltimo
    if len(arr) >= 2 and arr[-1] in (0, 1):
        print(arr[-2])
    else:
        print(arr[-1])
except Exception:
    print(0)
PY
