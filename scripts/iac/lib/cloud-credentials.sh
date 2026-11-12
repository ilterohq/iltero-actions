#!/bin/bash
#
# The environment variables each cloud's deploy credentials arrive in. deploy
# passes these to Terraform, and nothing else from the job's environment but
# PATH, HOME and TF_VAR_* values. Add a cloud by adding its names here.

# Used by the scripts that source this file.
# shellcheck disable=SC2034
readonly CLOUD_CREDENTIAL_ENV=(
  # AWS, as the AWS credentials action and the AWS CLI set them.
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE
)
