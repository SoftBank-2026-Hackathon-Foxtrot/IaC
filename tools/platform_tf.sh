#!/bin/zsh
# Terraform for environments/platform/aws with the foxtrot account: static keys from the
# `aws login` session (the Go SDK cannot read login_session profiles), the GCP project, and
# the Cloudflare/Tailscale provider tokens from Secrets Manager. Nothing is printed or stored.
#   tools/platform_tf.sh plan
#   tools/platform_tf.sh apply
set -e
export AWS_PROFILE=foxtrot AWS_REGION=ap-northeast-2
eval "$(aws configure export-credentials --profile foxtrot --format env)"
export TF_VAR_gcp_project_id="${TF_VAR_gcp_project_id:-foxtrot-513413}"
sec() { aws secretsmanager get-secret-value --secret-id "foxtrot/platform/$1" --query SecretString --output text; }
export CLOUDFLARE_API_TOKEN="$(sec cloudflare-iac-token)"
export TAILSCALE_API_KEY="$(sec tailscale-api-token)"
cd "$(dirname "$0")/../environments/platform/aws"
[ -d .terraform/providers ] || terraform init -backend-config="bucket=foxtrot-provisioner-state-$(aws sts get-caller-identity --query Account --output text)" -input=false
exec terraform "$@"
