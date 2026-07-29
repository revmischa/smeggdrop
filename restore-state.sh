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
# The bot reads state at cold start and caches it, so after a restore give it
# a new container -- redeploy, or wait for the warm ones to age out.
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${SMEGGDROP_AWS_PROFILE:-smeggdrop}"
REGION="${SMEGGDROP_AWS_REGION:-us-west-2}"
BUCKET="${SMEGGDROP_STATE_BUCKET:-smeggdrop-prod-statebucket-obvshxns}"
PREFIX="${SMEGGDROP_STATE_PREFIX:-state}"

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

usage() {
    cat >&2 <<'EOF'
roll the S3 proc library back to an earlier version

  ./restore-state.sh list                    versions, newest first
  ./restore-state.sh restore procs <version> put one back
  ./restore-state.sh verify                  does the live state still load?

override with SMEGGDROP_AWS_PROFILE / SMEGGDROP_AWS_REGION /
SMEGGDROP_STATE_BUCKET / SMEGGDROP_STATE_PREFIX
EOF
    exit 1
}

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

    # version ids are opaque and routinely contain +, / and =, all of which
    # change meaning inside a copy-source. Encode before interpolating.
    local ver_enc
    ver_enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$ver")

    echo "current version of $key is $current"
    echo "restoring $ver over it..."
    # copying an old version forward keeps the current one as history, so
    # this is undoable: re-run with the id printed above
    aws_ s3api copy-object --bucket "$BUCKET" --key "$key" \
        --copy-source "$BUCKET/$key?versionId=$ver_enc" \
        --metadata-directive COPY --query 'CopyObjectResult.ETag' --output text
    echo "done. to undo: $0 restore $cat $current"
}

cmd_verify() {
    local uri="s3://$BUCKET/$PREFIX"
    echo "loading $uri into a throwaway interpreter..."
    # stderr is left alone: when this fails it is usually aws auth or a
    # missing dependency, and swallowing that turns a clear error into a
    # bare non-zero exit
    local report
    report=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$report'" RETURN
    # to a file rather than a pipe: exiting non-zero from the reader closes
    # the pipe under the writer, and the BrokenPipeError that follows buries
    # the actual result
    AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" \
        uv run --quiet --with boto3 smeggdrop --state "$uri" audit --json > "$report"
    python3 - "$report" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["summary"]
bad = s["load_failures"] + s["var_load_failures"]
print(f"procs: {s['total']}   load failures: {s['load_failures']}"
      f"   var load failures: {s['var_load_failures']}")
sys.exit(1 if bad else 0)
PY
}

case "${1:-}" in
    list)    cmd_list ;;
    restore) shift; cmd_restore "$@" ;;
    verify)  cmd_verify ;;
    *)       usage ;;
esac
