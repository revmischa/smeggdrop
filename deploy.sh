#!/usr/bin/env bash
#
# Wrapper around sst that fixes credential resolution.
#
# The smeggdrop account is reached by assuming a role from an sso profile.
# The aws cli follows that chain fine, but sst's go sdk resolves
# `source_profile = mish` to the static keys in ~/.aws/credentials instead of
# the sso session and fails with InvalidClientTokenId. So resolve the chain
# with the cli and hand sst the temporary credentials that come out.
#
#   ./deploy.sh deploy          # deploy the prod stage
#   ./deploy.sh diff            # preview changes
#   ./deploy.sh secret list     # inspect secrets
#   STAGE=dev ./deploy.sh deploy
#
set -euo pipefail

PROFILE="${SMEGGDROP_AWS_PROFILE:-smeggdrop}"
STAGE="${STAGE:-prod}"

if [ $# -eq 0 ]; then
    set -- deploy
fi

creds="$(aws configure export-credentials --profile "$PROFILE" --format env)" || {
    echo "could not resolve credentials for profile '$PROFILE'." >&2
    echo "if the sso session expired: aws sso login --sso-session int80" >&2
    exit 1
}
eval "$creds"

# sst must not fall back to profile lookup now that the credentials are in env
unset AWS_PROFILE

echo "deploying stage '$STAGE' to account $(aws sts get-caller-identity --query Account --output text)"
exec npx sst "$@" --stage "$STAGE"
