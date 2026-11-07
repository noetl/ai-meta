#!/usr/bin/env bash
# usage: roll2.sh CONTEXT <deploy|sts> NAME CONTAINER image <image@digest>  [--apply]
#        roll2.sh CONTEXT <deploy|sts> NAME CONTAINER env   <VAR>=<value>   [--apply]
#        roll2.sh CONTEXT <deploy|sts> NAME CONTAINER unenv <VAR>           [--apply]
# Server-side dry-run first; diffs the WHOLE object against live and refuses unless
# the diff is exactly the one intended change (apply-safety.md). Then patches and
# waits for the rollout.
set -u
S=${OUT:-$(mktemp -d)}  # where before/dry/diff files are written
C=$1; T=$2; N=$3; CT=$4; KIND=$5; ARG=$6; MODE=${7:-}
k() { kubectl --context "$C" -n noetl "$@"; }
TAG=$(echo "$C-$N-$KIND" | tr -c 'a-zA-Z0-9-\n' '_')
case $KIND in
  image) P="{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$CT\",\"image\":\"$ARG\"}]}}}}"
         WANT='/spec/template/spec/containers\[[0-9]+\]/image:' ;;
  env)   V=${ARG%%=*}; VAL=${ARG#*=}
         P="{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$CT\",\"env\":[{\"name\":\"$V\",\"value\":\"$VAL\"}]}]}}}}"
         WANT='/spec/template/spec/containers\[[0-9]+\]/env: len [0-9]+ -> [0-9]+' ;;
  unenv) P="{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$CT\",\"env\":[{\"name\":\"$ARG\",\"\$patch\":\"delete\"}]}]}}}}"
         WANT='/spec/template/spec/containers\[[0-9]+\]/env: len [0-9]+ -> [0-9]+' ;;
  *) echo "kind must be image|env|unenv"; exit 2 ;;
esac
k get "$T" "$N" -o yaml > "$S/r2-before-$TAG.yaml" || exit 2
k patch "$T" "$N" --type strategic -p "$P" --dry-run=server -o yaml > "$S/r2-dry-$TAG.yaml" || exit 2
python3 -I - "$S/r2-before-$TAG.yaml" "$S/r2-dry-$TAG.yaml" > "$S/r2-diff-$TAG.txt" <<'PY'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1])); b = yaml.safe_load(open(sys.argv[2]))
out = []
def walk(x, y, p=""):
    if type(x) != type(y):
        out.append(f"{p}: {x} -> {y}"); return
    if isinstance(x, dict):
        for kk in sorted(set(x) | set(y)):
            if p == "" and kk == "status": continue
            if p == "/metadata" and kk not in ("labels", "annotations"): continue
            walk(x.get(kk), y.get(kk), p + "/" + kk)
    elif isinstance(x, list):
        if len(x) != len(y):
            out.append(f"{p}: len {len(x)} -> {len(y)}"); return
        for i, (u, v) in enumerate(zip(x, y)): walk(u, v, f"{p}[{i}]")
    elif x != y:
        out.append(f"{p}: {x} -> {y}")
walk(a, b); print("\n".join(out))
PY
cat "$S/r2-diff-$TAG.txt"
n=$(grep -c . "$S/r2-diff-$TAG.txt")
if [ "$n" != 1 ] || ! grep -qE "$WANT" "$S/r2-diff-$TAG.txt"; then
  echo "REFUSE: diff is not exactly the intended $KIND change ($n hunks)"; exit 3
fi
if [ "$KIND" = env ]; then
  python3 -I -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); c=[c for c in d['spec']['template']['spec']['containers'] if c['name']==sys.argv[2]][0]; e=[x for x in c.get('env',[]) if x['name']==sys.argv[3]]; print('dry env:', e); sys.exit(0 if e and e[0].get('value')==sys.argv[4] else 4)" "$S/r2-dry-$TAG.yaml" "$CT" "$V" "$VAL" || { echo "REFUSE: dry-run env not as intended"; exit 3; }
fi
[ "$MODE" = --apply ] || { echo "dry-run OK"; exit 0; }
date -u +"roll start %T"
k patch "$T" "$N" --type strategic -p "$P" && k rollout status "$T/$N" --timeout=900s
rc=$?
date -u +"roll end %T rc=$rc"
k get pods --no-headers | grep -E "^$N-"
exit $rc
