#!/usr/bin/env bash
# Point the app.foxtrot.live load balancer's "gcp" pool at the migration target of the moment.
# The Cloudflare account allows two load-balancer origins in all: pool "aws" holds the source, and
# this pool's one origin is switched to the target (our GCP app, on-prem, or the traffic part's
# test server). A migration always moves users between two places, so two pools are enough.
#
#   AWS_PROFILE=foxtrot tools/gcp_pool_origin.sh status
#   AWS_PROFILE=foxtrot tools/gcp_pool_origin.sh chiikawa   # tunnel foxtrot-chiikawa-gcp (our GCP app VM)
#   AWS_PROFILE=foxtrot ONPREM_TUNNEL_ID=<uuid> tools/gcp_pool_origin.sh onprem   # the on-prem app's tunnel
#   AWS_PROFILE=foxtrot tools/gcp_pool_origin.sh traffic    # tunnel foxtrot-traffic-gcp (test server)
#
# Switch while the pool is at 0%, then wait for its monitor (60 s) before moving users. Only the
# origin's address and name change: the pool's weight, its monitor and the traffic service's pool
# names stay. The target's tunnel must answer app.foxtrot.live and gcp.foxtrot.live (the monitor's
# Host). In the control-plane seed the target environment keeps trafficPool: gcp.
set -euo pipefail

ACCOUNT="${CF_ACCOUNT_ID:-3d6694c353d2e0519e3215805b763743}"
POOL="${CF_GCP_POOL_ID:-c02ba1a4acbbbb702fd2f67d6b6dc6a4}"
CHIIKAWA_TUNNEL="${CHIIKAWA_GCP_TUNNEL_ID:-3f67d63d-0a91-43ed-8090-c276563a6bc7}"  # foxtrot-chiikawa-gcp
TRAFFIC_TUNNEL="${TRAFFIC_GCP_TUNNEL_ID:-dcdc3044-beea-45a2-86cb-629a567b3a99}"   # foxtrot-traffic-gcp

case "${1:-status}" in
  chiikawa) NAME=chiikawa-gcp TUNNEL="$CHIIKAWA_TUNNEL" ;;
  traffic)  NAME=gcp-testapp  TUNNEL="$TRAFFIC_TUNNEL" ;;
  onprem)   NAME=onprem TUNNEL="${ONPREM_TUNNEL_ID:?set ONPREM_TUNNEL_ID to the on-prem app tunnel}" ;;
  status)   NAME="" ;;
  *) echo "usage: $0 status|chiikawa|onprem|traffic" >&2; exit 2 ;;
esac

TOKEN="${CLOUDFLARE_API_TOKEN:-$(aws secretsmanager get-secret-value --region ap-northeast-2 \
  --secret-id foxtrot/platform/cloudflare-api-token --query SecretString --output text)}"
API="https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/load_balancers/pools/${POOL}"
cf() { curl -fsS -A foxtrot-iac/1.0 -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" "$@"; }
show() { python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]
for o in r["origins"]: print(r["name"], "->", o["name"], o["address"], "enabled" if o.get("enabled") else "disabled")'; }

if [ -n "$NAME" ]; then
  BODY=$(printf '{"origins":[{"name":"%s","address":"%s.cfargotunnel.com","enabled":true,"weight":1,"header":{"Host":["app.foxtrot.live"]}}]}' "$NAME" "$TUNNEL")
  cf -X PATCH "$API" --data "$BODY" | show
else
  cf "$API" | show
fi
