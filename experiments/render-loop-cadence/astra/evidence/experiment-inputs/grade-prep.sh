#!/bin/zsh
# Re-capture every run with identical inputs, check objective gates, anonymize.
set -u
cd /Users/dara/Dev/Projects/weaver
OUT=/tmp/weaver-exp/final; rm -rf $OUT; mkdir -p $OUT
GR=/tmp/weaver-exp/grading; rm -rf $GR; mkdir -p $GR
CLOCK=2026-09-04T09:41:00.000Z
runs=(A1 A2 B1 B2 B3 B4 C1 C2 C3 C4)
# shuffle
shuf_runs=($(printf '%s\n' "${runs[@]}" | sort -R))
: > $GR/MAPPING.txt
i=0
for r in $shuf_runs; do
  i=$((i+1)); w=$(printf 'w%02d' $i)
  d=/tmp/weaver-exp/runs/$r
  echo "$w $r" >> $GR/MAPPING.txt
  chk=$(npx --no-install weaver check $d 2>&1 | tail -1)
  npx --no-install weaver capture $d --clock $CLOCK --out $OUT/$r-initial.png > $OUT/$r-initial.stdout 2> $OUT/$r-initial.stderr
  npx --no-install weaver capture $d --clock $CLOCK --action-file /tmp/weaver-exp/clicks.actions --out $OUT/$r-after.png > $OUT/$r-after.stdout 2> $OUT/$r-after.stderr
  s1=$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(j.status+(j.error?" "+j.error.code:""))}catch(e){console.log("no-receipt")}' $OUT/$r-initial.stdout)
  s2=$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(j.status+(j.error?" "+j.error.code:""))}catch(e){console.log("no-receipt")}' $OUT/$r-after.stdout)
  btn=$(grep -c 'role=button name="Log session"\|role=button name="Reset week"' $OUT/$r-initial.snapshot.txt 2>/dev/null || echo 0)
  lbl=$(grep -c '3 / 20' $OUT/$r-after.snapshot.txt 2>/dev/null || echo 0)
  ncap=$(ls $d/captures/*.png 2>/dev/null | wc -l | tr -d ' ')
  nsave=$(grep -c "	$r	" /tmp/weaver-exp/saves.log)
  first=$(grep "	$r	" /tmp/weaver-exp/saves.log | head -1 | cut -f1)
  last=$(grep "	$r	" /tmp/weaver-exp/saves.log | tail -1 | cut -f1)
  lines=$(wc -l < $d/widget.tsx | tr -d ' ')
  echo "$r	check=$chk	initial=$s1	after=$s2	buttons=$btn	label3of20=$lbl	captures=$ncap	saves=$nsave	lines=$lines	first=$first	last=$last" >> $OUT/GATES.tsv
  mkdir -p $GR/$w
  cp $OUT/$r-initial.png $GR/$w/initial.png 2>/dev/null
  cp $OUT/$r-after.png $GR/$w/after.png 2>/dev/null
  cp $OUT/$r-initial.snapshot.txt $GR/$w/initial.snapshot.txt 2>/dev/null
  cp $OUT/$r-after.snapshot.txt $GR/$w/after.snapshot.txt 2>/dev/null
  sed 's/Condition[^\n]*//' $d/widget.tsx > $GR/$w/widget.tsx
done
echo done; cat $OUT/GATES.tsv
