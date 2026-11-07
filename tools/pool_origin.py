#!/usr/bin/env python3
"""Point one of app.foxtrot.live's two load-balancer pools at an environment's tunnel.

The Cloudflare account allows two load-balancer origins in all, so the two pools ("aws" and "gcp",
the names the traffic service and the control-plane seed use) are slots, not clouds: a migration
moves users between two places, and the place that is not serving takes the free slot.

  aws -> gcp -> onprem : aws in pool aws, gcp in pool gcp; then onprem into pool aws (aws at 0%)
  onprem -> gcp -> aws : onprem in pool aws, gcp in pool gcp; then aws into pool aws (onprem at 0%)
  aws <-> onprem       : onprem into pool gcp

The pool name is what goes into the seed's trafficPool for that environment.

  AWS_PROFILE=foxtrot tools/pool_origin.py status
  AWS_PROFILE=foxtrot tools/pool_origin.py aws onprem       # pool aws -> tunnel foxtrot-chiikawa-onprem
  AWS_PROFILE=foxtrot tools/pool_origin.py gcp gcp --wait   # and wait until the pool's monitor sees it

Refused unless it is safe:
  * the pool must carry no traffic (its load-balancer weight is 0); FORCE=1 overrides;
  * the tunnel must answer the Host the pool's monitor sends (the aws tunnel answers only
    aws.foxtrot.live, so aws can only sit in pool aws).
Only the origin changes: the pool's weight, its monitor and the pool names stay.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

ACCOUNT = os.environ.get("CF_ACCOUNT_ID", "3d6694c353d2e0519e3215805b763743")
ZONE = os.environ.get("CF_ZONE", "foxtrot.live")
LB_HOST = os.environ.get("CF_LB_HOST", "app.foxtrot.live")
POOLS = json.loads(os.environ.get("CF_POOL_IDS", json.dumps({
    "aws": "b26f0a79ed2d63568022f5b0ffd2b00d",
    "gcp": "c02ba1a4acbbbb702fd2f67d6b6dc6a4",
})))
# Environment -> the tunnel that serves its app. Looked up by name, so a recreated tunnel needs no edit.
TUNNELS = {
    "aws": "foxtrot-traffic-aws",          # run by the chiikawa AWS app VM since the 11-06 handover
    "gcp": "foxtrot-chiikawa-gcp",         # run by the chiikawa GCP app VM
    "onprem": "foxtrot-chiikawa-onprem",   # run by cloudflared on the on-prem host
    "traffic-gcp": "foxtrot-traffic-gcp",  # the traffic part's GCP test server
}
API = "https://api.cloudflare.com/client/v4"


def token():
    if t := os.environ.get("CLOUDFLARE_API_TOKEN"):
        return t
    return subprocess.run(
        ["aws", "secretsmanager", "get-secret-value", "--region", "ap-northeast-2",
         "--secret-id", "foxtrot/platform/cloudflare-api-token", "--query", "SecretString", "--output", "text"],
        check=True, capture_output=True, text=True).stdout.strip()


TOKEN = None


def cf(path, method="GET", body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json",
                                          "User-Agent": "foxtrot-iac/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)["result"]
    except urllib.error.HTTPError as e:
        sys.exit(f"cloudflare {method} {path}: {e.code} {e.read().decode()[:300]}")


def acc(path):
    return f"/accounts/{ACCOUNT}{path}"


def tunnel_by_name(name):
    found = cf(acc(f"/cfd_tunnel?name={name}&is_deleted=false"))
    if not found:
        sys.exit(f"tunnel {name} not found (not applied yet?)")
    return found[0]


def tunnel_hosts(tunnel_id):
    config = (cf(acc(f"/cfd_tunnel/{tunnel_id}/configurations")) or {}).get("config") or {}
    return {i["hostname"] for i in config.get("ingress", []) if i.get("hostname")}


def lb_weights():
    zone = cf(f"/zones?name={ZONE}")[0]["id"]
    lb = next(l for l in cf(f"/zones/{zone}/load_balancers") if l["name"] == LB_HOST)
    rs = lb.get("random_steering") or {}
    return {pid: rs.get("pool_weights", {}).get(pid, rs.get("default_weight", 1)) for pid in lb["default_pools"]}


def health_counts(pool_id):
    """(healthy, checked) over the monitor's regions; (0, 0) before the first check."""
    try:
        pops = cf(acc(f"/load_balancers/pools/{pool_id}/health")).get("pop_health", {})
    except SystemExit:
        return 0, 0
    states = [o.get("healthy") for p in pops.values() for origin in p.get("origins", []) for o in origin.values()]
    return sum(1 for s in states if s), len(states)


def health(pool_id):
    ok, total = health_counts(pool_id)
    return f"{ok}/{total} healthy" if total else "no checks yet"


def env_of(address):
    tid = address.removesuffix(".cfargotunnel.com")
    for env, name in TUNNELS.items():
        try:
            if tunnel_by_name(name)["id"] == tid:
                return env
        except SystemExit:
            continue
    return "?"


def status():
    weights = lb_weights()
    for slot, pid in POOLS.items():
        p = cf(acc(f"/load_balancers/pools/{pid}"))
        for o in p["origins"]:
            print(f"pool {slot:4} weight={weights.get(pid, '?')}  origin {o['name']} -> {env_of(o['address'])}"
                  f" ({o['address']})  {'enabled' if o.get('enabled') else 'disabled'}  monitor: {health(pid)}")


def switch(slot, env, wait):
    if slot not in POOLS:
        sys.exit(f"pool must be one of {sorted(POOLS)}")
    if env not in TUNNELS:
        sys.exit(f"environment must be one of {sorted(TUNNELS)}")
    pid = POOLS[slot]
    pool = cf(acc(f"/load_balancers/pools/{pid}"))
    weight = lb_weights().get(pid, 0)
    if weight and os.environ.get("FORCE") != "1":
        sys.exit(f"pool {slot} carries traffic (weight {weight}); move users off it first, or FORCE=1")
    tunnel = tunnel_by_name(TUNNELS[env])
    monitor_host = LB_HOST
    if pool.get("monitor"):
        monitor = cf(acc(f"/load_balancers/monitors/{pool['monitor']}"))
        monitor_host = ((monitor.get("header") or {}).get("Host") or [LB_HOST])[0]
    hosts = tunnel_hosts(tunnel["id"])
    missing = {LB_HOST, monitor_host} - hosts
    if missing:
        sys.exit(f"tunnel {tunnel['name']} does not answer {sorted(missing)} (pool {slot}'s users/monitor);"
                 f" it answers {sorted(hosts)}")
    other = [s for s, p in POOLS.items() if p != pid and any(
        o["address"].startswith(tunnel["id"]) for o in cf(acc(f"/load_balancers/pools/{p}"))["origins"])]
    if other:
        print(f"note: pool {other[0]} already points at {tunnel['name']}")
    origin = {"name": f"chiikawa-{env}" if not env.startswith("traffic") else env, "enabled": True, "weight": 1,
              "address": f"{tunnel['id']}.cfargotunnel.com", "header": {"Host": [LB_HOST]}}
    cf(acc(f"/load_balancers/pools/{pid}"), "PATCH", {"origins": [origin]})
    print(f"pool {slot} -> {env} ({tunnel['name']})")
    if wait:
        deadline = time.time() + 240
        time.sleep(15)  # let the monitor run against the new origin before trusting its result
        while time.time() < deadline:
            ok, total = health_counts(pid)
            print(f"  monitor: {ok}/{total} healthy")
            if total and ok == total:
                break
            time.sleep(15)
        else:
            sys.exit(f"pool {slot} not healthy after 4 min: check cloudflared on the {env} side")


def main(argv):
    global TOKEN
    TOKEN = token()
    args = [a for a in argv if a != "--wait"]
    if not args or args == ["status"]:
        return status()
    if len(args) != 2:
        sys.exit(__doc__)
    switch(args[0], args[1], "--wait" in argv)


if __name__ == "__main__":
    main(sys.argv[1:])
