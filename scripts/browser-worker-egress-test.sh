#!/usr/bin/env bash
# scripts/browser-worker-egress-test.sh
# Proves the NetworkPolicy blocks RFC1918 + cloud-metadata egress while
# allowing public HTTPS. Uses node's TCP connect (present in the image) so we
# distinguish "blocked at network layer" (timeout) from "reachable". The
# Kubernetes API ClusterIP is a real RFC1918 endpoint reachable WITHOUT the
# policy, so blocking it genuinely proves enforcement (not just an absent target).
set -euo pipefail
NS=browser
POD=browser-worker-0

probe() {  # host port -> REACHABLE | BLOCKED | BLOCKED:<code>
  kubectl -n "$NS" exec "$POD" -- node -e '
    const net=require("net");
    const s=net.connect({host:process.argv[1],port:+process.argv[2],timeout:5000});
    s.on("connect",()=>{console.log("REACHABLE");s.destroy();process.exit(0)});
    s.on("timeout",()=>{console.log("BLOCKED");s.destroy();process.exit(0)});
    s.on("error",e=>{console.log("BLOCKED:"+e.code);process.exit(0)});
  ' "$1" "$2"
}

API_IP=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
echo "cluster API ClusterIP (RFC1918): $API_IP"

echo "=== 0. positive control: a pod NOT selected by the policy must REACH the API ClusterIP ==="
kubectl -n default run np-control --image=browser-worker:dev --image-pull-policy=IfNotPresent --restart=Never \
  --command -- sleep 60 >/dev/null 2>&1 || true
kubectl -n default wait --for=condition=Ready pod/np-control --timeout=60s >/dev/null 2>&1 || true
ctrl=$(kubectl -n default exec np-control -- node -e '
  const net=require("net");const s=net.connect({host:process.argv[1],port:443,timeout:5000});
  s.on("connect",()=>{console.log("REACHABLE");s.destroy();process.exit(0)});
  s.on("timeout",()=>{console.log("BLOCKED");process.exit(0)});
  s.on("error",e=>{console.log("BLOCKED:"+e.code);process.exit(0)});' "$API_IP" 2>/dev/null || echo "EXECFAIL")
kubectl -n default delete pod np-control --now --ignore-not-found >/dev/null 2>&1 || true
echo "control (default ns) -> $API_IP:443 = $ctrl"
echo "$ctrl" | grep -q REACHABLE || { echo "FAIL: control pod could not reach API ClusterIP — cannot verify NetworkPolicy enforcement (the later 'blocked' results would be inconclusive)"; exit 1; }

echo "=== 1. public HTTPS must be REACHABLE ==="
pub=$(probe example.com 443); echo "example.com:443 -> $pub"
echo "$pub" | grep -q REACHABLE || { echo "FAIL: public HTTPS blocked unexpectedly"; exit 1; }

echo "=== 2. in-cluster RFC1918 (API server) must be BLOCKED ==="
api=$(probe "$API_IP" 443); echo "$API_IP:443 -> $api"
echo "$api" | grep -q BLOCKED || { echo "FAIL: RFC1918 reachable — NetworkPolicy NOT enforced"; exit 1; }

echo "=== 3. cloud-metadata IP must be BLOCKED ==="
meta=$(probe 169.254.169.254 80); echo "169.254.169.254:80 -> $meta"
echo "$meta" | grep -q BLOCKED || { echo "FAIL: metadata reachable"; exit 1; }

echo "PASS: control verified reachable; public reachable; RFC1918 + metadata blocked (NetworkPolicy enforced)"
