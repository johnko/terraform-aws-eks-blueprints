#!/usr/bin/env bash
set -eo pipefail

if [[ -e .envrc ]]; then
  set +x
  # hide secret env values from output
  # shellcheck disable=SC1091
  source .envrc
fi

if [[ -z $IAC_BIN ]]; then
  set -x
  export IAC_BIN=terraform
  set +x
fi

WORKSPACE="$1"
if [[ -z $WORKSPACE ]]; then
  echo "ERROR: missing 'WORKSPACE' as 1st argument"
  exit 1
fi
if [[ ! -d $WORKSPACE ]]; then
  echo "ERROR: invalid 'WORKSPACE', received '$WORKSPACE'"
  exit 1
fi
echo "WORKSPACE=$WORKSPACE"
pushd "$WORKSPACE"

ACTION="$2"
if [[ -z $ACTION ]]; then
  echo "ERROR: missing 'ACTION' as 1st argument"
  exit 1
fi
# transform the action arg into uppercase
SAFE_ACTION=$(echo "$ACTION" | tr '[:lower:]' '[:upper:]')
case $SAFE_ACTION in
  APPLY | AUTO | FMT | INIT | PLAN | VALIDATE)
    echo "ACTION=$ACTION"
    ;;
  *)
    echo "ERROR: invalid 'ACTION', received '$ACTION'"
    exit 1
    ;;
esac
echo "SAFE_ACTION=$SAFE_ACTION"

# Load above workspace specific secrets
if [[ -e ../.envrc ]]; then
  set +x
  # hide secret env values from output
  # shellcheck disable=SC1091
  source ../.envrc
fi
# Load workspace specific secrets
if [[ -e .envrc ]]; then
  set +x
  # hide secret env values from output
  # shellcheck disable=SC1091
  source .envrc
fi

if [[ -e shared_tfstate_backend.template ]]; then
  if [[ -z $TF_VAR_workspace ]]; then
    TF_VAR_workspace="$WORKSPACE"
    export TF_VAR_workspace
  fi
  envsubst <shared_tfstate_backend.template >shared_tfstate_backend.tf
fi

if [[ -n $CROSS_ACCOUNT_PIPELINE_IAM_ROLE ]] && [[ -n $TF_VAR_aws_account_id ]]; then
  ROLE_ARN="arn:aws:iam::$TF_VAR_aws_account_id:role/$CROSS_ACCOUNT_PIPELINE_IAM_ROLE"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  # Hide command
  set +x
  # Assume the Cross Account Role
  # shellcheck disable=SC2046
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<$(
    aws sts assume-role \
      --role-arn "$ROLE_ARN" \
      --role-session-name "terraform-pipeline" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text
  )
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN
  echo "Assumed role $ROLE_ARN"
  aws sts get-caller-identity --output text
fi

set -ux
$IAC_BIN fmt

set +x
if [[ "FMT" == "$SAFE_ACTION" ]]; then
  set -x
  exit 0
fi
if [[ "VALIDATE" == "$SAFE_ACTION" ]] && [[ "true" == "$CI" ]]; then
  [[ -e shared_tfstate_backend.tf ]] && rm shared_tfstate_backend.tf
fi

set -x
set +e
$IAC_BIN init
TF_INIT_EXIT_CODE=$?
set +x
if [[ "INIT" == "$SAFE_ACTION" || "0" != "$TF_INIT_EXIT_CODE" ]]; then
  set -x
  $IAC_BIN providers
  set -e
  exit $TF_INIT_EXIT_CODE
fi

set -x
set +e
$IAC_BIN validate
TF_VALIDATE_EXIT_CODE=$?
set +x
if [[ "VALIDATE" == "$SAFE_ACTION" || "0" != "$TF_VALIDATE_EXIT_CODE" ]]; then
  set -x
  set -e
  exit $TF_VALIDATE_EXIT_CODE
fi

set +x
if [[ "APPLY" == "$SAFE_ACTION" || "AUTO" == "$SAFE_ACTION" || "PLAN" == "$SAFE_ACTION" ]]; then
  if [[ -e _import.sh ]]; then
    set -x
    bash -ex _import.sh
    TF_IMPORT_EXIT_CODE=$?
    set -e
    if [[ $TF_IMPORT_EXIT_CODE != 0 ]]; then
      exit $TF_IMPORT_EXIT_CODE
    fi
  fi
fi

set +x
if [[ "PLAN" == "$SAFE_ACTION" ]]; then
  set -x
  set +e
  $IAC_BIN plan -detailed-exitcode -input=false -out=tfplan.tfplan
  TF_PLAN_EXIT_CODE=$?
  # 0 = Succeeded with empty diff (no changes), need to stop pipeline from going to TerraformApply
  # 2 = Succeeded with non-empty diff (changes present), need to continues pipeline to ApproveOrReject and TerraformApply
  # 1 = Error
  set -e
  exit $TF_PLAN_EXIT_CODE
fi

set +x
if [[ "APPLY" == "$SAFE_ACTION" || "AUTO" == "$SAFE_ACTION" ]]; then
  AUTO_APPROVE_ARG=""
  TFPLAN_FILE=""
  if [[ "AUTO" == "$SAFE_ACTION" ]]; then
    AUTO_APPROVE_ARG="-auto-approve"
    TFPLAN_FILE="tfplan.tfplan"
  fi
  set -x
  set +e
  $IAC_BIN apply $AUTO_APPROVE_ARG -input=false $TFPLAN_FILE
  TF_APPLY_EXIT_CODE=$?
  set -e
  exit $TF_APPLY_EXIT_CODE
fi

popd
