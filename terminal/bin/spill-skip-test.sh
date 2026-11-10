#!/usr/bin/env bash
# spill-skip-test.sh - v1.2 endurance path: prove a SAME-NAME re-spill re-stamps instead of rewrites.
# Sequence A,B,A,B then stop: A spills at the first B-switch (write), A is cold-read, and the SECOND
# B-switch re-refuses A -> files exist + manifest line present -> expected: log shows 're-stamped,
# bytes unchanged' and the .ses mtimes do NOT move while the manifest pk does.
set -uo pipefail
S=/mnt/scratch/naz/Projects/strata
LAUNCH=/home/naz/.local/state/strata/launch
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
json.dump({"model":"strata","messages":[{"role":"user","content":text}],"max_tokens":256,"temperature":0},open(out+"/body_sk.json","w"))
PY
curl -s -m 1200 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$URL" --data-binary @"$R/body_sk.json" \
  | python3 -c "import json,sys;d=json.load(sys.stdin);c=(d['choices'][0]['message']['content'] or '')[:40];print('  turn $1 ->',c)" 2>/dev/null; }

rm -rf $PARK; mkdir -p $PARK
printf 'strata-park 2\ntag stub00000000000\nstages 2\nend\n' > $PARK/park.manifest
( cd $S && CONFIG=$CFG ./strata-serve start > $R/boot_sk.log 2>&1 )
for i in $(seq 1 40); do grep -aq 'ready:' <(tail -4 $R/boot_sk.log) && break; sleep 10; done
echo "booted $(date +%H:%M:%S)"
turn SALTA001 SKIP-A-741
turn SALTB002 SKIP-B-741          # -> A spill #1 (real write)
MT1=$(stat -c %Y $PARK/c*-380*9*-s1.ses 2>/dev/null | head -1); ls -la $PARK/*.ses | awk '{print "  after-spill1:", $5, $9}'
turn SALTA001 SKIP-A-741          # cold re-read of A
turn SALTB002 SKIP-B-741          # -> A spill #2 = SKIP PATH (re-stamp)
N=$(grep -an 'engine started' $L | tail -1 | cut -d: -f1)
echo "-- spill lines this boot:"; tail -n +$N $L | grep -a 'spilled' | grep -oE 'spilled [0-9]+ tokens.*' | cut -c1-100
MT2=$(stat -c %Y $PARK/c*-380*9*-s1.ses 2>/dev/null | head -1)
grep -aq 're-stamped, bytes unchanged' <(tail -n +$N $L) && [ "$MT1" = "$MT2" ] \
  && echo "PASS skip-path: re-stamp logged AND stage mtimes unchanged" || echo "FAIL skip-path (mtimes $MT1/$MT2)"
( cd $S && CONFIG=$CFG ./strata-serve stop >/dev/null 2>&1 )
echo "done $(date +%H:%M:%S)"
