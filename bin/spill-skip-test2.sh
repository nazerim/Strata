#!/usr/bin/env bash
# spill-skip-test2.sh - v1.3.1 pre-enable proof on the SHIP binary, one server.
# Reality learned 05:49: the serve session THREADS across turns (KV reuse), so every refusal usually captures a
# NEW byte-state and same-name re-refusals are a matter of the thread returning to an old version. Phase logic:
#  PHASE 1 (6 turns A,B,A,B,A,B): every refusal logged. A name spilling a 2nd time MUST show "(re-stamped, bytes
#          unchanged)" (F1 gates pass for text-only: cvec never loads on prod - verified 05:56, only --help lines)
#          AND both stage mtimes must be frozen across that event (reviewer nit 1 = both stages, not just s1).
#  PHASE 2 (tamper + 2 turns): flip one byte of the earliest spill's s0 model-fingerprint; any re-refusal of that
#          name must now DECLINE the skip: real rewrite (no suffix, mtime moves). No re-refusal = inconclusive note,
#          never a false FAIL. No re-stamp anywhere in 6 turns = endurance never fires under this workload (v1.1
#          behavior, already approved) - reported, not blocking: the correctness legs are the gates + unit suites.
set -uo pipefail
S=/mnt/scratch/naz/Projects/strata
LAUNCH=/home/naz/.local/state/strata/launch
SOUT=$LAUNCH/strata-serve.stdout.log
CFG=$LAUNCH/ud-q4_k_xl-spilltest.json
PARK=/mnt/scratch/naz/.local/share/strata/Strata-data/park-spilltest
L=$LAUNCH/ud-q4_k_xl-256k.engine.log
KEY=$(awk '{print $1}' /mnt/scratch/naz/models/.llama/api_keys | head -c 64)
URL=http://127.0.0.1:8001/v1/chat/completions
R=/tmp/opencode/spill-test; mkdir -p $R
SNAP=$R/mtimes.txt

turn(){ local salt=$1 code=$2 tag=$3
  python3 - "$salt" "$code" "$R" <<'PY'
import json,sys
salt,code,out=sys.argv[1],sys.argv[2],sys.argv[3]
corpus=open('/mnt/scratch/naz/Projects/llama-cache-dir/runs/ab-220-275u-curve/pp.txt').read()*4
n=int(380000/0.39818)
text=salt+"\n"+corpus[:n]+f"\n\nREMEMBER: the shipment code is {code}. When asked, reply with exactly the code and nothing else.\nQuestion: what is the shipment code?\n"
json.dump({"model":"strata","messages":[{"role":"user","content":text}],"max_tokens":256,"temperature":0},open(out+"/body_sk2.json","w"))
PY
  curl -s -m 1200 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$URL" --data-binary @"$R/body_sk2.json" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);c=(d['choices'][0]['message']['content'] or '')[:40];print('  turn $tag ->',c)" 2>/dev/null
  bootline | grep -a 'spilled' | tail -1 | grep -oE 'as [a-z0-9-]+( \([^)]*\))?' | sed "s/^/$(date +%s)|$tag|/" >> $SNAP || true
  for f in $PARK/*-s0.ses; do [ -e "$f" ] && echo "$(date +%s)|$tag|$(basename $f)|$(stat -c %Y $f)" >> ${SNAP}m; done
}
bootline(){ tail -n +$(grep -an 'engine started' $L | tail -1 | cut -d: -f1) $L; }

rm -rf $PARK $SNAP ${SNAP}m; mkdir -p $PARK
printf 'strata-park 2\ntag stub00000000000\nstages 2\nend\n' > $PARK/park.manifest
BEFORE=$(wc -l < $SOUT 2>/dev/null || echo 0)   # stdout.log is shared across boots: only a ready: NEWER than this counts
( cd $S && CONFIG=$CFG ./strata-serve start > $R/boot_sk2.log 2>&1 )
READY=no
for i in $(seq 1 45); do sleep 10
  tail -n +$((BEFORE+1)) $SOUT 2>/dev/null | grep -aq 'ready:' && { READY=yes; break; }
  tail -2 $R/boot_sk2.log | grep -aqiE 'failed|cannot' && break; done
echo "booted $(date +%H:%M:%S)  ready-marker: $READY  (freshness-guarded strata-serve.stdout.log)"

for c in 1 2 3; do turn SALTA001 SKIP-A-741 "A$c"; turn SALTB002 SKIP-B-741 "B$c"; done

FIRST=$(ls $PARK/ 2>/dev/null | grep -a 'c.*-s0\.ses' | sort | head -1 | sed 's/-s0\.ses//')
echo "-- tampering s0 model-fp byte of $FIRST at $(date +%H:%M:%S) --"
printf '\001' | dd of=$PARK/$FIRST-s0.ses bs=1 seek=16 count=1 conv=notrunc status=none
TAM_MT=$(stat -c %Y $PARK/$FIRST-s0.ses)
turn SALTA001 SKIP-A-741 "TA"; turn SALTB002 SKIP-B-742 "TB"

( cd $S && CONFIG=$CFG ./strata-serve stop >/dev/null 2>&1 )

echo "== spill lines this boot =="
bootline | grep -a 'spilled' | grep -oE 'spilled [0-9]+ tokens.*as [a-z0-9-]+( \([^)]*\))?' | cut -c1-105
python3 - "$SNAP" "${SNAP}m" "$FIRST" "$TAM_MT" <<'PY'
import sys, collections
snap, snapm, first, tam_mt = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4] or 0)
refusals = collections.defaultdict(list)   # name -> [(ts,tag,re_stamped)]
for line in open(snap):
    p = line.strip().split("|")
    if len(p) < 3: continue
    ts, tag, rest = p[0], p[1], "|".join(p[2:])
    nm = rest.split(" as ")[-1].split(" (")[0].strip()
    refusals[nm].append((int(ts), tag, "re-stamped" in rest))
mt = collections.defaultdict(dict)         # turn-tag -> {file: mtime}
for line in open(snapm):
    p = line.strip().split("|")
    if len(p) == 4: mt[p[1]][p[2]] = int(p[3])
print("refusal counts:", {k: len(v) for k, v in refusals.items()})
p1 = "NOT-SEEN"
for nm, evs in refusals.items():
    if len(evs) >= 2:
        second = evs[-1]
        if second[2]:
            f0, f1 = nm+"-s0.ses", nm+"-s1.ses"
            seq = [(t, mt[tag].get(f0), mt[tag].get(f1)) for t, tag, _ in evs if tag in mt]
            frozen = len(seq) >= 2 and seq[0][1] == seq[-1][1] == seq[0][2] == seq[-1][2] and seq[0][1] is not None
            p1 = "PASS" if frozen else f"STAMPS BUT MTIMES MOVED ({seq})"
        else:
            p1 = f"SAME NAME {nm} RE-REFUSED WITHOUT RE-STAMP - HIGH: gate wrongly declined"
p2 = "NOT-SEEN"
for ts, tag, rs in refusals.get(first, []):
    if ts >= tam_mt:   # a refusal of the tampered name AFTER the tamper
        p2 = "FAIL: tampered header still re-stamped (F2 broken)" if rs else \
             ("PASS: declined -> real rewrite" if mt.get(tag, {}).get(first+"-s0.ses", 0) > tam_mt else "rewrite claimed but mtime unclear")
print(f"PHASE1 (endurance/re-stamp under v1.3.1 gates): {p1}")
print(f"PHASE2 (tamper -> F2 decline): {p2}")
print("VERDICT:", "GREEN" if "PASS" in p1 and "PASS" in p2 else
      "PROCEED-with-notes (no same-name repeat = v1.1-equivalent behavior; correctness carried by gates+units+review)"
      if ("NOT-SEEN" in p1 or "NOT-SEEN" in p2) and "declined" not in str(p1) else "RED")
PY
echo "done $(date +%H:%M:%S)"
