#!/bin/bash
#
# The AWS adapter: the environment variables AWS credentials arrive in, and
# the mock credentials the preview gives the IaC tool. lib/cloud-credentials.sh
# sources this file.

# The variables the AWS credentials action and the AWS CLI set, and the ones
# that point to AWS's settings files and to the certificates to trust when
# calling AWS. deploy passes them to the IaC tool.
CLOUD_CREDENTIAL_ENV+=(
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE
  AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_CA_BUNDLE
)

# The mock credential and the region the preview gives the IaC tool. Neither
# reaches AWS: the tool's adapter skips every credential check.
readonly AWS_PREVIEW_MOCK_CREDENTIAL="iltero-preview-mock"
readonly AWS_PREVIEW_REGION="us-east-1"

# The mock credentials, so the tool never looks for real ones.
PREVIEW_CREDENTIAL_ENV+=(
  AWS_ACCESS_KEY_ID="${AWS_PREVIEW_MOCK_CREDENTIAL}"
  AWS_SECRET_ACCESS_KEY="${AWS_PREVIEW_MOCK_CREDENTIAL}"
  AWS_EC2_METADATA_DISABLED=true
  AWS_REGION="${AWS_PREVIEW_REGION}"
)
