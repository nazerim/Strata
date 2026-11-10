#!/usr/bin/env bash
# spill-skip-test2.sh - v1.3.1 end-to-end proof before enable, one server:
#  PHASE 1 (endurance): A,B,A,B like test 1; re-stamp must fire AND BOTH stage mtimes (s0+s1) must freeze (nit 1).
#  PHASE 2 (F2 decline): flip one byte of the s0 model fingerprint (offset 16) -> the next same-name refusal must
#          find the header untrustworthy -> skip declines -> FULL rewrite (no 're-stamped' suffix, s0 mtime moves).
#          Proves the header gate AND the fall-through path on the binary that ships tonight.
#  Also records the boot-time control-vector state (F1's second gate must not veto the prod text workload).
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
turn(){ python3 - "$1" "$2" "$R" <<'PY'
import json,sys
salt,code,out=sys.argv[1],sys.argv[2],sys.argv[3]
corpus=open('/mnt/scratch/naz/Projects/llama-cache-dir/runs/ab-220-275u-curve/pp.txt').read()*4
n=int(380000/0.39818)
text=salt+"\n"+corpus[:n]+f"\n\nREMEMBER: the shipment code is {code}. When asked, reply with exactly the code and nothing else.\nQuestion: what is the shipment code?\n"
json.dump({"model":"strata","messages":[{"role":"user","content":text}],"max_tokens":256,"temperature":0},open(out+"/body_sk2.json","w"))
PY
curl -s -m 1200 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$URL" --data-binary @"$R/body_sk2.json" \
  | python3 -c "import json,sys;d=json.load(sys.stdin);c=(d['choices'][0]['message']['content'] or '')[:40];print('  turn $1 ->',c)" 2>/dev/null; }
bootline(){ tail -n +$(grep -an 'engine started' $L | tail -1 | cut -d: -f1) $L; }

rm -rf $PARK; mkdir -p $PARK
printf 'strata-park 2\ntag stub00000000000\nstages 2\nend\n' > $PARK/park.manifest
BEFORE=$(wc -l < $SOUT 2>/dev/null || echo 0)   # stdout.log is shared across boots: only a ready: NEWER than this counts
( cd $S && CONFIG=$CFG ./strata-serve start > $R/boot_sk2.log 2>&1 )
READY=no
for i in $(seq 1 45); do sleep 10
  tail -n +$((BEFORE+1)) $SOUT 2>/dev/null | grep -aq 'ready:' && { READY=yes; break; }
  tail -1 $R/boot_sk2.log | grep -aqE 'failed|error' && break; done
[ "$READY" = yes ] || echo "  (ready: marker absent after loop - continuing on engine-log evidence)"
echo "booted+ready $(date +%H:%M:%S)  [marker: strata-serve.stdout.log, freshness-guarded]"   # ready: lives in stdout.log (naz note 05:37) - the wrapper log never carried it (test-1's 400 s was its timeout, not a detection)
bootline | grep -aiE 'cvec|control vector' | tail -2 | cut -c1-100
echo "-- cvec grep count: $(bootline | grep -acE 'cvec' || true) --"

turn SALTA001 SKIP-A-741
turn SALTB002 SKIP-B-741          # -> A spill #1 (real write)
S0=$PARK/$(ls $PARK | grep -a 'c.*-s0\.ses' | head -1)
S1=$PARK/$(ls $PARK | grep -a 'c.*-s1\.ses' | head -1)
M0A=$(stat -c %Y "$S0"); M1A=$(stat -c %Y "$S1"); echo "  spill1 stages: $S0 @ $M0A | $S1 @ $M1A"
turn SALTA001 SKIP-A-741          # cold re-read of A
turn SALTB002 SKIP-B-741          # -> A spill #2 = SKIP PATH (re-stamp)
M0B=$(stat -c %Y "$S0"); M1B=$(stat -c %Y "$S1")
P1="FAIL"; bootline | grep -a 're-stamped, bytes unchanged' >/dev/null && [ "$M0A" = "$M0B" ] && [ "$M1A" = "$M1B" ] \
  && P1="PASS" && echo "PHASE1 PASS: re-stamp + BOTH stage mtimes frozen ($M0A/$M1A)" || echo "PHASE1 FAIL (mtimes $M0A->$M0B, $M1A->$M1B)"

# phase 2: make the on-disk s0 header untrustworthy (model fp byte), the next refusal must rewrite for real
printf '\001' | dd of="$S0" bs=1 seek=16 count=1 conv=notrunc status=none
echo "  tampered s0 model-fp byte $(date +%H:%M:%S)"
turn SALTA001 SKIP-A-741
turn SALTB002 SKIP-B-742          # -> A spill #3: header declined -> full rewrite
M0C=$(stat -c %Y "$S0")
N2=$(bootline | grep -ac 'spilled .* tokens .* to disk as c[0-9a-f]*-' || true)
S2=$(bootline | grep -a 'spilled' | tail -1 | cut -c1-110)
P2="FAIL"; [ "$M0C" -gt "$M0A" ] && ! echo "$S2" | grep -aq 're-stamped' && P2="PASS" \
  && echo "PHASE2 PASS: tamper declined the skip, s0 rewritten (mtime $M0A->$M0C)" || echo "PHASE2 FAIL: last spill line: $S2"
echo "spill lines total this boot: $N2"; bootline | grep -a 'spilled' | grep -oE 'spilled [0-9]+ tokens.*as [a-z0-9-]+( \([^)]*\))?' | cut -c1-105
( cd $S && CONFIG=$CFG ./strata-serve stop >/dev/null 2>&1 )
echo "OVERALL: $P1 / $P2   done $(date +%H:%M:%S)"
