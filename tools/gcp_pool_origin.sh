#!/usr/bin/env bash
# Point the app.foxtrot.live load balancer's "gcp" pool at one GCP app or the other.
# The Cloudflare account allows two load-balancer origins in all, so the chiikawa app and the
# traffic part's test server share this pool's one origin; switch it for a test and back after.
#
#   AWS_PROFILE=foxtrot tools/gcp_pool_origin.sh status
#   AWS_PROFILE=foxtrot tools/gcp_pool_origin.sh chiikawa   # tunnel foxtrot-chiikawa-gcp (our app VM)
#   AWS_PROFILE=foxtrot tools/gcp_pool_origin.sh traffic    # tunnel foxtrot-traffic-gcp (test server)
#
# Only the origin's address and name change: the pool's weight in the load balancer, its monitor
# and the traffic service's pool names stay, so a pool at 0% stays at 0%.
set -euo pipefail

ACCOUNT="${CF_ACCOUNT_ID:-3d6694c353d2e0519e3215805b763743}"
POOL="${CF_GCP_POOL_ID:-c02ba1a4acbbbb702fd2f67d6b6dc6a4}"
CHIIKAWA_TUNNEL="${CHIIKAWA_GCP_TUNNEL_ID:-3f67d63d-0a91-43ed-8090-c276563a6bc7}"  # foxtrot-chiikawa-gcp
TRAFFIC_TUNNEL="${TRAFFIC_GCP_TUNNEL_ID:-dcdc3044-beea-45a2-86cb-629a567b3a99}"   # foxtrot-traffic-gcp

case "${1:-status}" in
  chiikawa) NAME=chiikawa-gcp TUNNEL="$CHIIKAWA_TUNNEL" ;;
  traffic)  NAME=gcp-testapp  TUNNEL="$TRAFFIC_TUNNEL" ;;
  status)   NAME="" ;;
  *) echo "usage: $0 status|chiikawa|traffic" >&2; exit 2 ;;
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
