#!/usr/bin/env bash
# spill-restore-test.sh v3 — G3 WINDOW ONLY (PRECONDITION: prod stopped, :8001 free - enforced below).
# Proves PLAN-spill-restore.md §4: a spilled conversation is RESTORED from disk mid-run when its thread is
# re-requested. Rebuilt after independent review #2 (all 10 findings): short fillers (giants destroyed the
# newest-2 candidate cap), count-delta precondition, 400-token growth margin for A2, THE <20% WALL ASSERT
# actually measured (own cold baseline turn), prod-guard + boot short-circuit, post-restart phase scripted.
# v3 adds review #2's N4: the H3 stdout assertion - NO 'SESSION' protocol line may appear in the engine's
# stdout log across the A2 turn (boot's PARKLOAD SESSIONs are baselined away; any NEW one is a mid-request leak).
# Total window cost ~30 min (A1 + B1 + 2 shorts + A2 + BASE cold-giant ≈ 3.5 giants; I2's Z1 is a 4th).
set -uo pipefail
MODE=${1:-full}
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
health(){ curl -sf -m 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:8001/health >/dev/null 2>&1; }
spill_count(){ bootline | grep -ac 'conversation cache: spilled' || true; }
restore_count(){ bootline | grep -ac 'spill restore: .*loaded' || true; }   # loaded-lines only - declines never count

body(){ python3 - "$1" "$2" "$3" "$R/body.json" <<'PY'
import json,sys
salt,code,extra=sys.argv[1],sys.argv[2],sys.argv[3]
if salt.startswith("FILLER"):                       # SHORT by intent (review #2 finding 1): eviction hygiene +
    text=salt+"\n"+"Short filler "+salt[-1]+": name three moons of Jupiter, one line."   # negative path (fits RAM
else:                                               # -> must NEVER spill; must never enter A2's candidate set
    corpus=open('/mnt/scratch/naz/Projects/llama-cache-dir/runs/ab-220-275u-curve/pp.txt').read()*4
    text=salt+"\n"+corpus[:int(380000/0.39818)]+f"\n\nREMEMBER: the shipment code is {code}. When asked, reply with exactly the code and nothing else.\nQuestion: what is the shipment code?\n"
if extra: text += "\n" + extra                       # A2's growth passage (~400 tokens, finding 3)
json.dump({"model":"strata","messages":[{"role":"user","content":text}],"max_tokens":256,"temperature":0},open(sys.argv[4],"w"))
PY
}
turn(){ local tag=$1 salt=$2 code=$3 extra=${4:-}
  body "$salt" "$code" "$extra"
  local T0=$(date +%s)
  curl -s -m 1200 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$URL" --data-binary @$R/body.json \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print((d['choices'][0]['message']['content'] or '')[:80])" > $R/ans-$tag.txt 2>/dev/null || : > $R/ans-$tag.txt
  echo $(( $(date +%s)-T0 )) > $R/wall-$tag.txt
  say "turn $tag -> $(cat $R/ans-$tag.txt | head -c 60) ($(( $(date +%s)-T0 )) s)"
}
# ~300-token growth passage so request_len - tk(A1) lands >> assistant-turn framing noise (finding 3), << 16384
GROW="Now, as a final instruction for the archive, do three things. First, state the shipment code once more, exactly, followed by the date 2026-11-11. Second, list four procedural safeguards a warehouse should apply when a coded shipment crosses a jurisdictional boundary, each in one numbered sentence. Third, write a two-sentence summary of why deterministic recall of coded identifiers matters more for audit chains than for routine logistics, and close by repeating the identifier alone on the final line. Please be brief and factual, and remember that the response will be checked by an automated verifier that compares tokens literally, so punctuation and casing of the identifier must match what you were told earlier, character for character, with no surrounding quotation marks or commentary on the same final line as the identifier itself. The archive format expects the identifier to appear exactly twice in the whole response: once in the first sentence of the restated form and once alone on the final line. Any deviation, paraphrase, expansion, or additional occurrence will fail verification and trigger a costly manual review cycle. This instruction block was appended to the thread after the original conversation and represents the grown request the restore path must serve from disk state plus a new tail."

check_I1(){ local tag=$1 want=$2
  local N=$(restore_count) ANS=$(cat $R/ans-$tag.txt) OK
  grep -qa "$want" $R/ans-$tag.txt && ANSOK=yes || ANSOK=BAD
  if [ "$N" -ge 1 ] && [ "$ANSOK" = yes ] && [ "${H3_LEAK:-no}" != yes ]; then OK=yes; else OK=no; fi
  local W2=$(cat $R/wall-$tag.txt 2>/dev/null || echo 9999) WB=$(cat $R/wall-BASE.txt 2>/dev/null || echo 9999)
  local FAST=NA; [ "$WB" != 9999 ] && { [ "$W2" -lt $((WB/5)) ] && FAST=yes || FAST=no; }
  REST_OK=$([ "$OK" = yes ] && [ "$FAST" = yes ] && echo PASS || echo "$OK(ans=$ANSOK restores=$N wall=$W2 vs cold $WB fast=$FAST)")
  say "restore lines loaded: $N | last: $(bootline | grep -a 'spill restore: .*loaded' | tail -1 | cut -c1-160)"
  say "I1 verdict: answer=$( [ $ANSOK = yes ] && echo ok || echo BAD) restores=$N wallA2=${W2}s coldBASE=${WB}s -> $REST_OK"
}

if [ "$MODE" = post-restart ]; then
  # G3 phase 2 (finding 5): operator restarted the restoretest server after the stop below; the boot-load may
  # or may not cover A1 - the restore path must beat cold REGARDLESS when the grown thread re-requests.
  health || { say "FATAL: :8001 not healthy - start the restoretest config first"; exit 1; }
  # wall-BASE is phase-1's cold giant if it survived (/tmp persists across the restart; tmpfs does not)
  turn A3 SALTR001 RST-A-741 "$GROW"
  check_I1 A3 RST-A-741
  bootline | grep -aq 'took the parked conversation' && say "follow-on take line present (I3 expectation) " || say "note: no 'took the parked' line (boot-load may have served instead - inspect)"
  echo "== POST-RESTART RESULT: $REST_OK =="; exit 0
fi

# ---------------- full G3 run ----------------
[ -x "$EXE" ] || { say "FATAL: $EXE not built (G1-G3 gate not reached?)"; exit 1; }
health && { say "FATAL: something already answers :8001 - prod must be stopped first (finding 6)"; exit 1; }

rm -rf $PARK; mkdir -p $PARK
printf 'strata-park 2\ntag stub00000000000\nstages 2\nend\n' > $PARK/park.manifest
python3 - "$LAUNCH" "$EXE" "$PARK" "$CFG" <<'PY'
import json,sys
launch,exe,park,cfg=sys.argv[1:5]
d=json.load(open(launch+"/ud-q4_k_xl-256k.json"))
d["exe"]=exe; d["port"]=8001
d["env"]=dict(d.get("env",{})); d["env"]["STRATA_PARK_DIR"]=park
d["env"]["STRATA_PARK_SPILL"]="1"; d["env"]["STRATA_PARK_RESTORE"]="1"
json.dump(d,open(cfg,"w"),indent=1)
PY

( cd $S && CONFIG=$CFG ./strata-serve start > $R/boot.log 2>&1 )
READY=no
for i in $(seq 1 72); do sleep 10
  health && { READY=yes; break; }
  tail -3 $R/boot.log | grep -aqiE 'failed|cannot|error' && break; done
[ "$READY" = yes ] || { say "FATAL: restoretest server never became healthy (boot.log): $(tail -2 $R/boot.log | cut -c1-100)"; exit 1; }
say "booted+healthy (marker: /health poll)"

# ---- I1: A1 -> B1 (count-delta proves A's spill) -> 2 SHORT fillers -> grown A2 must restore from disk ----
turn A1 SALTR001 RST-A-741
P0=$(spill_count)
turn B1 SALTR002 RST-B-741                    # outgoing A1 cannot be admitted -> spills (the only way to get
SP1=$(spill_count)                            # a spill line here is A1: B1 becomes active, nothing else exists)
if [ "$SP1" -gt "$P0" ] && bootline | grep -a 'conversation cache: spilled' | tail -1 | grep -aq 'as c'; then
  say "I1 precondition OK: A1 spilled to disk ($(bootline | grep -a 'spilled' | tail -1 | grep -oE 'as [a-z0-9-]+' | tail -1))"
else say "I1 PRECONDITION FAIL: no new spill at B1 - budget admitted A1 (shrink --conversation-cache-mib in a copy config and re-run)"; exit 1; fi
turn F1 FILLER001 F-1
turn F2 FILLER002 F-2                          # short: parkable, NEVER spills, never enters candidate set

SOUT=/home/naz/.local/state/strata/launch/strata-serve.stdout.log   # engine stdout (SESSION protocol lines land here)
SESS0=$(grep -ac '^SESSION ' $SOUT 2>/dev/null); SESS0=${SESS0:-0}
turn A2 SALTR001 RST-A-741 "$GROW"             # grown re-request: cache has F1/F2 (+maybe B1); A1 exists only on disk
SESS1=$(grep -ac '^SESSION ' $SOUT 2>/dev/null); SESS1=${SESS1:-0}
H3_LEAK=no; [ "$SESS1" -gt "$SESS0" ] && H3_LEAK=yes
say "H3 stdout isolation across A2: SESSION lines $SESS0 -> $SESS1 ($([ $H3_LEAK = yes ] && echo LEAK-FAIL || echo clean))"
turn BASE SALTBASE9 RST-BASE-0 "ignore the above code question and simply print the word COLD."   # cold baseline (unique salt, giant) - AFTER A2 so it cannot perturb candidates
check_I1 A2 RST-A-741

# ---- I2: absent conversation -> restore declines are NAMED and silent-safe (Z1 is a giant, +~150 s cost) ----
turn Z1 SALTZ901 RST-Z-999
bootline | grep -a 'spill restore: candidate .* declined' > $R/declines.txt
say "I2 decline lines observed this boot: $(wc -l < $R/declines.txt) (zero is valid when no candidate existed; non-zero must each name a reason)"

# ---- I3: stop; files + manifest consistent; scripted post-restart repeat ----
( cd $S && CONFIG=$CFG ./strata-serve stop >/dev/null 2>&1 ); say "stopped"
ls $PARK/*.ses 2>/dev/null | wc -l | xargs say "I3 .ses files on disk:"
tail -6 $PARK/park.manifest | sed 's/^/    /'
say "I3 NEXT (window step): restart with the SAME config, then run:  bash $0 post-restart"

echo "== SUMMARY =="
echo "I1 (restore fires + correct + <20% of cold + no SESSION leak): $REST_OK"
echo "I2 declines: $(cat $R/declines.txt)"
echo "I3: run the restart + post-restart phase to close the matrix"
