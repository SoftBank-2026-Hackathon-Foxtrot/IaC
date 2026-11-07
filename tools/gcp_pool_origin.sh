#!/usr/bin/env bash
# Kept for the commands already in notes and runbooks; tools/pool_origin.py does the work and can
# switch either pool. This one only ever touches the "gcp" pool, as before.
#
#   AWS_PROFILE=foxtrot tools/gcp_pool_origin.sh status
#   AWS_PROFILE=foxtrot tools/gcp_pool_origin.sh chiikawa   # tunnel foxtrot-chiikawa-gcp (our GCP app VM)
#   AWS_PROFILE=foxtrot tools/gcp_pool_origin.sh onprem     # tunnel foxtrot-chiikawa-onprem
#   AWS_PROFILE=foxtrot tools/gcp_pool_origin.sh traffic    # tunnel foxtrot-traffic-gcp (test server)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
case "${1:-status}" in
  status)   exec python3 "$HERE/pool_origin.py" status ;;
  chiikawa) exec python3 "$HERE/pool_origin.py" gcp gcp ;;
  onprem)   exec python3 "$HERE/pool_origin.py" gcp onprem ;;
  traffic)  exec python3 "$HERE/pool_origin.py" gcp traffic-gcp ;;
  *) echo "usage: $0 status|chiikawa|onprem|traffic" >&2; exit 2 ;;
esac
