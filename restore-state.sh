#!/usr/bin/env bash
#
# Roll the S3 proc library back to an earlier version.
#
# The store keeps one object per category, so a bad eval rewrites the whole
# blob -- which is exactly what bucket versioning is for. Every write leaves
# the previous copy intact, and restoring is copying an old version back over
# the current one (which itself becomes a new version, so a restore is
# reversible too).
#
#   ./restore-state.sh list                 # what can I roll back to?
#   ./restore-state.sh restore procs <id>   # put that version back
#   ./restore-state.sh verify               # does the live state still load?
#
# The bot reads state at cold start and caches it, so after a restore give it
# a new container -- redeploy, or wait for the warm ones to age out.
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${SMEGGDROP_AWS_PROFILE:-smeggdrop}"
REGION="${SMEGGDROP_AWS_REGION:-us-west-2}"
BUCKET="${SMEGGDROP_STATE_BUCKET:-smeggdrop-prod-statebucket-obvshxns}"
PREFIX="${SMEGGDROP_STATE_PREFIX:-state}"

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

cmd_list() {
    for cat in procs vars; do
        echo "== $cat =="
        aws_ s3api list-object-versions --bucket "$BUCKET" \
            --prefix "$PREFIX/$cat.json" \
            --query "reverse(sort_by(Versions, &LastModified))[].{When:LastModified,Size:Size,Current:IsLatest,Version:VersionId}" \
            --output table
    done
}

cmd_restore() {
    local cat="${1:-}" ver="${2:-}"
    case "$cat" in procs|vars) ;; *) echo "category must be procs or vars" >&2; exit 1;; esac
    [ -n "$ver" ] || { echo "need a version id (see: $0 list)" >&2; exit 1; }

    local key="$PREFIX/$cat.json"
    local current
    current=$(aws_ s3api head-object --bucket "$BUCKET" --key "$key" --query VersionId --output text)
    echo "current version of $key is $current"
    echo "restoring $ver over it..."
    # copying an old version forward keeps the current one as history, so
    # this is undoable: re-run with the id printed above
    aws_ s3api copy-object --bucket "$BUCKET" --key "$key" \
        --copy-source "$BUCKET/$key?versionId=$ver" \
        --metadata-directive COPY --query 'CopyObjectResult.ETag' --output text
    echo "done. to undo: $0 restore $cat $current"
}

cmd_verify() {
    local uri="s3://$BUCKET/$PREFIX"
    echo "loading $uri into a throwaway interpreter..."
    AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" \
        uv run --quiet --with boto3 smeggdrop --state "$uri" audit --json 2>/dev/null \
        | uv run --quiet python -c '
import json, sys
r = json.load(sys.stdin)
tot = r.get("total") or len(r.get("procs", []))
bad = r.get("load_errors") or 0
print(f"procs loaded: {tot}   load errors: {bad}")
sys.exit(1 if bad else 0)'
}

case "${1:-}" in
    list)    cmd_list ;;
    restore) shift; cmd_restore "$@" ;;
    verify)  cmd_verify ;;
    *)       usage ;;
esac
