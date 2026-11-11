#!/usr/bin/env bash
# spill-restore-test.sh — G3 WINDOW ONLY (needs a restart; do not run without naz's window).
# Proves PLAN-spill-restore.md §4: a conversation spilled to disk mid-run is RESTORED from disk (not cold-
# prefilled) when its thread is re-requested and no RAM copy survives. Sequence per I1/I2/I3 below.
# Expects: binary at Strata-build/restore/strata; config generated here; fresh park dir.
set -uo pipefail
S=/mnt/scratch/naz/Projects/strata
LAUNCH=/home/naz/.local/state/strata/launch
EXE=/mnt/scratch/naz/Projects/Strata-build/restore/strata
PARK=/mnt/scratch/naz/.local/share/strata/Strata-data/park-restoretest
CFG=$LAUNCH/ud-q4_k_xl-restoretest.json
KEY=$(awk '{print $1}' /mnt/scratch/naz/models/.llama/api_keys | head -c 64)
URL=http://127.0.0.1:8001/v1/chat/completions
R=/tmp/opencode/restore-test; mkdir -p $R
L=$LAUNCH/ud-q4_k_xl-256k.engine.log
bootline(){ tail -n +$(grep -an 'engine started' $L | tail -1 | cut -d: -f1) $L; }
say(){ echo "[$(date +%H:%M:%S)] $*"; }

# request body: salted 380K-giant with needle; optional extra user-turn appended (grown thread)
body(){ python3 - "$1" "$2" "$3" "$R/body.json" <<'PY'
import json,sys
salt,code,extra,out=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
corpus=open('/mnt/scratch/naz/Projects/llama-cache-dir/runs/ab-220-275u-curve/pp.txt').read()*4
text=salt+"\n"+corpus[:int(380000/0.39818)]+f"\n\nREMEMBER: the shipment code is {code}. When asked, reply with exactly the code and nothing else.\nQuestion: what is the shipment code?\n"
if extra: text += "\n" + extra
json.dump({"model":"strata","messages":[{"role":"user","content":text}],"max_tokens":256,"temperature":0},open(out,"w"))
PY
}
turn(){ local tag=$1 salt=$2 code=$3 extra=${4:-}
  body "$salt" "$code" "$extra"
  local T0=$(date +%s)
  curl -s -m 1200 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$URL" --data-binary @$R/body.json \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print((d['choices'][0]['message']['content'] or '')[:40])" > $R/ans-$tag.txt 2>/dev/null
  say "turn $tag -> $(cat $R/ans-$tag.txt) ($(( $(date +%s)-T0 )) s)"
}

# ---- config (fresh dir; BOTH gates; park budget tiny so RAM cannot hoard copies -> forces the restore path) ----
rm -rf $PARK; mkdir -p $PARK
printf 'strata-park 2\ntag stub00000000000\nstages 2\nend\n' > $PARK/park.manifest
python3 - <<PY
import json
d=json.load(open("$LAUNCH/ud-q4_k_xl-256k.json"))
d["exe"]="$EXE"; d["port"]=8001
d["env"]=dict(d.get("env",{})); d["env"]["STRATA_PARK_DIR"]="$PARK"
d["env"]["STRATA_PARK_SPILL"]="1"; d["env"]["STRATA_PARK_RESTORE"]="1"
json.dump(d,open("$CFG","w"),indent=1)
PY

( cd $S && CONFIG=$CFG ./strata-serve start > $R/boot.log 2>&1 )
for i in $(seq 1 72); do sleep 10
  curl -sf -m 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:8001/health >/dev/null 2>&1 && break; done
say "booted+healthy"

# ---- I1: spill A, flush RAM copies with fillers, re-request GROWN A -> must restore from disk ----
turn A1 SALTR001 RST-A-741
turn B1 SALTR002 RST-B-741                    # refuses A1 -> real spill
for i in 1 2 3 4; do turn F$i FILLER0$i F-1 "Short filler $i: name three moons of Jupiter."; done   # evict RAM copies
bootline | grep -a 'spilled' | tail -1 | grep -aq 'as c' && say "I1 precondition: A spilled to disk OK" || say "I1 PRECONDITION FAIL (no spill happened - cache had room; shrink budget and re-run)"
turn A2 SALTR001 RST-A-741 "And now state the code once more with the date 2026-11-11."
N2=$(bootline | grep -ac 'spill restore: .*loaded' || true)
T2=$(bootline | grep -a 'spill restore' | tail -1 | cut -c1-160)
grep -aq 'RST-A-741' $R/ans-A2.txt && REST_OK=$([ "$N2" -ge 1 ] && echo yes || echo no) || REST_OK=no
say "I1 verdict: answer=$([ "$(grep -ac RST-A-741 $R/ans-A2.txt)" = 1 ] && echo ok || echo BAD) restore_lines=$N2 [$T2]"

# ---- I2: grown request of an aged/absent conversation -> named declines, request completes cold ----
turn Z1 SALTZ901 RST-Z-999
bootline | grep -a 'spill restore: candidate .* declined' | tail -2 > $R/declines.txt
say "I2 decline-path lines captured: $(wc -l < $R/declines.txt) (inspect; zero is also valid if window had no candidates)"

# ---- I3: stop/restart cycle - manifest + files consistent, restore still fires post-restart ----
( cd $S && CONFIG=$CFG ./strata-serve stop >/dev/null 2>&1 ); say "stopped"
ls $PARK/*.ses 2>/dev/null | wc -l | xargs say "I3 files on disk:"
cat $PARK/park.manifest | tail -6 | sed 's/^/    /'
say "I3 restart-by-operator (window step, then repeat I1's A2-only turns and expect restore from boot-load OR disk - either path must beat cold prefill)"

echo "== SUMMARY =="
echo "I1 restore fired: $REST_OK  (expect yes; wall of A2 in turn log above vs cold baseline ~160s at 380K)"
echo "I1 answer correct: $(cat $R/ans-A2.txt)"
echo "declines seen: $(cat $R/declines.txt)"
