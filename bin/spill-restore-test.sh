#!/usr/bin/env bash
# spill-restore-test.sh v5 — G3 WINDOW ONLY (PRECONDITION: prod stopped, :8001 free - enforced below).
# Proves PLAN-spill-restore.md §4: a spilled conversation is RESTORED from disk mid-run when its thread is
# re-requested. Lineage: v2 = review #2 (FIX-BEFORE-WINDOW, all 10 findings); v4/v4.1 = real-class size +
# /dev/shm RAM holder; v5 = the THREAD SHAPE the mechanism actually serves.
#
# Why v5: v4.1 ran the full contract correctly - the candidate was selected, passed identity, passed the
# pre-screen, was read at boot-rate (2784 MiB in 1642.6 ms) and fell through CLEANLY - but reused only its
# 16384-token ROOT checkpoint, because a SINGLE-TURN thread serializes {root, live} and live (prompt+answer)
# is never a prefix of the grown re-request (it diverges at the answer's first token, and conversation_prefix
# is all-or-nothing per state). Real agent threads - the lane's actual workload - have checkpoints at every
# turn boundary (the night's 59,501-tok RAM restore was one). v5's thread A therefore runs TWO turns before
# spilling, and the grown A2 request must reuse the deepest turn-boundary checkpoint (~150 K) and read only
# the tail. Z1 is sized 200 K so A's young lines (tk ~168 K) are guaranteed IN-WINDOW candidates for it -
# which the pre-screen must name-decline (the I2 proof v4.1 could not exercise: same-size siblings fall
# silently outside the strict upper bound).
#
# The spill leg is forced deterministically with a 2 GiB /dev/shm RAM holder across A1X's park (mirroring
# the real-traffic MemAvailable pressure that produced the night's spills; park REFUSES admission, the spill
# capture rides reclaimable page cache by design - the v1.3 F1 review note), released before A2 so the
# ~2.8 GB restore read admits (avail is logged on both sides).
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
avail_mib(){ awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo; }
holder(){ # "holder on <MiB>" / "holder off": shrink or restore MemAvailable (forces RAM-admission refusal at the next park -> spill)
  if [ "$1" = on ]; then dd if=/dev/zero of=/dev/shm/g3-holder bs=1M count=$2 status=none
    say "RAM holder ON: $2 MiB (avail now $(avail_mib) MiB)"
  else rm -f /dev/shm/g3-holder
    say "RAM holder OFF (avail now $(avail_mib) MiB)"
  fi; }

body(){ python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$R/body.json" <<'PY'
import json,sys
salt,code,extra,target,mode,ansfile,out = sys.argv[1:8]
corpus=open('/mnt/scratch/naz/Projects/llama-cache-dir/runs/ab-220-275u-curve/pp.txt').read()*4
corpus=corpus[:int(int(target)/0.39818)]
user1=salt+"\n"+corpus+f"\n\nREMEMBER: the shipment code is {code}. When asked, reply with exactly the code and nothing else.\nQuestion: what is the shipment code?\n"
if mode=="multi":
    assistant=open(ansfile).read()
    user2="Restate the identifier and the date 2026-11-11 on separate lines, identifier first."+("\n"+extra if extra else "")
    msgs=[{"role":"user","content":user1},{"role":"assistant","content":assistant},{"role":"user","content":user2}]
else:
    text=user1+("\n"+extra if extra else "")
    msgs=[{"role":"user","content":text}]
json.dump({"model":"strata","messages":msgs,"max_tokens":256,"temperature":0},open(out,"w"))
PY
}
turn(){ local tag=$1 salt=$2 code=$3 extra=${4:-} target=${5:-165000} mode=${6:-single}
  body "$salt" "$code" "$extra" "$target" "$mode" "$R/full-A1.txt"
  local T0=$(date +%s)
  curl -s -m 1200 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$URL" --data-binary @$R/body.json \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['choices'][0]['message']['content'] or '')" > $R/full-$tag.txt 2>/dev/null || : > $R/full-$tag.txt
  cp $R/full-$tag.txt $R/ans-$tag.txt
  local W=$(( $(date +%s)-T0 )); echo $W > $R/wall-$tag.txt
  say "turn $tag ($mode/$target) -> $(head -c 60 $R/full-$tag.txt | tr '\n' ' ') (${W} s)"
}
# ~300-token growth passage: request_len lands >> assistant-turn framing noise beyond the thread's serialized
# states (review #2 finding 3), yet stays far under the 16384-token gain ceiling questions
GROW="Now, as a final instruction for the archive, do three things. First, state the shipment code once more, exactly, followed by the date 2026-11-11. Second, list four procedural safeguards a warehouse should apply when a coded shipment crosses a jurisdictional boundary, each in one numbered sentence. Third, write a two-sentence summary of why deterministic recall of coded identifiers matters more for audit chains than for routine logistics, and close by repeating the identifier alone on the final line. Please be brief and factual, and remember that the response will be checked by an automated verifier that compares tokens literally, so punctuation and casing of the identifier must match what you were told earlier, character for character, with no surrounding quotation marks or commentary on the same final line as the identifier itself. The archive format expects the identifier to appear exactly twice in the whole response: once in the first sentence of the restated form and once alone on the final line. Any deviation, paraphrase, expansion, or additional occurrence will fail verification and trigger a costly manual review cycle. This instruction block was appended to the thread after the original conversation and represents the grown request the restore path must serve from disk state plus a new tail."

check_I1(){ local tag=$1 want=$2 base=${3:-BASE}
  local N=$(restore_count) OK
  grep -qa "$want" $R/full-$tag.txt && local ANSOK=yes || local ANSOK=BAD
  local W2=$(cat $R/wall-$tag.txt 2>/dev/null || echo 9999) WB=$(cat $R/wall-$base.txt 2>/dev/null || echo 9999)
  local FAST=NA; [ "$WB" != 9999 ] && { [ "$W2" -lt $((WB/5)) ] && FAST=yes || FAST=no; }
  [ "$N" -ge 1 ] && [ "$ANSOK" = yes ] && [ "${H3_LEAK:-no}" != yes ] && OK=yes || OK=no
  REST_OK=$([ "$OK" = yes ] && [ "$FAST" = yes ] && echo PASS || echo "$OK(ans=$ANSOK restores=$N wall=${W2}s cold=${WB}s fast=$FAST leak=${H3_LEAK:-n/a}))")
  say "restore lines loaded: $N | last: $(bootline | grep -a 'spill restore: .*loaded' | tail -1 | cut -c1-170)"
  say "I1 verdict: $REST_OK"
}

if [ "$MODE" = post-restart ]; then
  # G3 phase 2: operator restarted the restoretest server; boot-load may or may not already cover thread A -
  # the grown re-request must be FAST and correct either way (boot-load take or mid-run restore).
  health || { say "FATAL: :8001 not healthy - start the restoretest config first"; exit 1; }
  [ -f $R/wall-BASE.txt ] || echo 9999 > $R/wall-BASE.txt
  SESS0=$(grep -ac '^SESSION ' /home/naz/.local/state/strata/launch/strata-serve.stdout.log 2>/dev/null); SESS0=${SESS0:-0}
  turn A3 SALTR001 RST-A-741 "$GROW" 165000 multi
  SOUT=/home/naz/.local/state/strata/launch/strata-serve.stdout.log
  SESS1=$(grep -ac '^SESSION ' $SOUT 2>/dev/null); SESS1=${SESS1:-0}
  H3_LEAK=no; [ "$SESS1" -gt "$SESS0" ] && H3_LEAK=yes
  bootline | grep -aq 'took the parked conversation' && say "take line present (boot-load or restore - either feeds it)" || say "note: no take line this boot"
  check_I1 A3 RST-A-741 BASE
  echo "== POST-RESTART RESULT: $REST_OK =="; exit 0
fi

# ---------------- full G3 run ----------------
[ -x "$EXE" ] || { say "FATAL: $EXE not built"; exit 1; }
health && { say "FATAL: something already answers :8001 - prod must be stopped first"; exit 1; }
rm -f /dev/shm/g3-holder

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
[ "$READY" = yes ] || { say "FATAL: restoretest server never became healthy: $(tail -2 $R/boot.log | cut -c1-100)"; exit 1; }
say "booted+healthy (marker: /health poll; avail $(avail_mib) MiB)"

# ---- I1: thread A turns 1+2 -> holder ON -> B1 (A1X spills) -> shorts -> holder OFF -> grown A2 restores ----
turn A1 SALTR001 RST-A-741 "" 165000 single
turn A1X SALTR001 RST-A-741 "Restate the identifier and the date 2026-11-11 on separate lines, identifier first." 165000 multi
P0=$(spill_count)
holder on 2048                                  # A1X's park will refuse admission -> spills (capture rides reclaimable cache by design)
turn B1 SALTR002 RST-B-741                      # outgoing thread-A conversation cannot be admitted -> spills
SP1=$(spill_count)
if [ "$SP1" -gt "$P0" ] && bootline | grep -a 'conversation cache: spilled' | tail -1 | grep -aq 'as c'; then
  say "I1 precondition OK: thread A spilled ($(bootline | grep -a 'spilled' | tail -1 | grep -oE 'as [a-z0-9-]+' | tail -1))"
else say "I1 PRECONDITION FAIL: no new spill at B1 - budget admitted thread A"; exit 1; fi
turn F1 FILLER001 F-1
turn F2 FILLER002 F-2                           # 135-138 tok: below min_tokens, never park/spill/disk - hygiene only
holder off                                      # A2's restore read must admit (~2.8 GB image on ~5.4 GiB avail)

SOUT=/home/naz/.local/state/strata/launch/strata-serve.stdout.log
SESS0=$(grep -ac '^SESSION ' $SOUT 2>/dev/null); SESS0=${SESS0:-0}
turn A2 SALTR001 RST-A-741 "$GROW" 165000 multi  # grown re-request: thread A exists ONLY on disk (or evicted RAM)
SESS1=$(grep -ac '^SESSION ' $SOUT 2>/dev/null); SESS1=${SESS1:-0}
H3_LEAK=no; [ "$SESS1" -gt "$SESS0" ] && H3_LEAK=yes
say "H3 stdout isolation across A2: SESSION lines $SESS0 -> $SESS1 ($([ $H3_LEAK = yes ] && echo LEAK-FAIL || echo clean))"
turn BASE SALTBASE9 RST-BASE-0 "ignore the above code question and simply print the word COLD."   # cold baseline, unique salt, AFTER A2
check_I1 A2 RST-A-741 BASE

# ---- I2: same-root different-thread giant at 200 K: A's young lines (~168 K) are IN-WINDOW for it and the
#      pre-screen must DECLINE them by name (a silent zero here would mean the selector never ran) ----
turn Z1 SALTZ901 RST-Z-999 "" 200000 single
bootline | grep -a 'spill restore: candidate .* declined' > $R/declines.txt
say "I2 decline lines observed this boot: $(wc -l < $R/declines.txt) (must be >0 now; each names its reason)"

# ---- I3: stop; files + manifest consistent; scripted post-restart repeat ----
( cd $S && CONFIG=$CFG ./strata-serve stop >/dev/null 2>&1 ); say "stopped"
ls $PARK/*.ses 2>/dev/null | wc -l | xargs say "I3 .ses files on disk:"
tail -6 $PARK/park.manifest | sed 's/^/    /'
say "I3 NEXT (window step): restart with the SAME config, then run:  bash $0 post-restart"

echo "== SUMMARY =="
echo "I1 (restore fires + correct + <20% of cold + no SESSION leak): $REST_OK"
echo "I2 declines: $(cat $R/declines.txt)"
echo "I3: run the restart + post-restart phase to close the matrix"
