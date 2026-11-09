#!/bin/bash
#
# Records one stage of one container image's change. The build stage, plan,
# runs in the pipeline run that built and pushed the image. The deployment
# stages, pre_deploy, post_deploy and post_verify, run in the job that deploys
# it. The workflow builds, pushes, scans and deploys the image itself; this
# script passes the files those tools wrote to the CLI's check of the stage. It
# runs no build, scan or deployment.
#
# Usage:
#   image/record.sh check STAGE    Refuse untrusted events and pull request review events, and on
#                                  pull_request events any stage but plan; check the stage's name
#                                  and that setup ran.
#   image/record.sh run STAGE      Run the CLI's check of STAGE for UNIT; write the job summary.
#
# Run from the project's working directory. In a project linked to the
# server, the plan stage's check opens or joins the build run of the pipeline
# run for APPLICATION, and sends the image's record. A project with no
# platform section in .iltero/config.yml records locally: no run, no upload.
# On a pull request event, the plan stage runs locally, linked or not, as
# advice: failed or undecided assertions exit 0. The CLI records a deployment
# only in a project with no platform section, and always locally.
#
# The CLI keeps the deployment's record in RECORDS_DIRECTORY. Each deployment
# stage after pre_deploy reads the record from it, so a later stage in a
# different job needs the records directory of the earlier job.
#
# Environment:
#   IMAGE                        The image: repository[:tag]@sha256:<digest> at plan, and
#                                repository@sha256:<digest> at pre_deploy and post_deploy.
#   APPLICATION                  The application the image is of, as the server names it.
#   ENVIRONMENT                  The environment the image is deployed to.
#   UNIT                         The unit the image is built from or deployed as.
#   BUILD_METADATA               The metadata file of `docker buildx build --metadata-file`.
#   IMAGE_INDEX                  The image's index, exactly as the registry holds it.
#   ATTESTATION                  The build's signed provenance, a Sigstore bundle.
#   TEST_REPORTS                 JUnit XML test reports, one path per line.
#   SCAN_REPORTS                 Scan reports, one per line: the scanner's name, a space, the report's path.
#   CLUSTER_ID                   The uid of the cluster's kube-system namespace.
#   WORKLOAD_BEFORE_PODS_LISTING The workload, read before its pods.
#   PODS                         The workload's pods.
#   POD_OWNERS                   A Deployment's ReplicaSets.
#   WORKLOAD_AFTER_PODS_LISTING  The workload, read again after its pods.
#   RECORDS_DIRECTORY            Where the CLI keeps the records. Empty: a directory in RUNNER_TEMP for
#                                builds, and one for each environment for deployments.
#   ARTIFACT_NAME                The records artifact's name. Empty: iltero-image-records-<unit> for
#                                plan, iltero-image-deployment-records-<environment>-<unit> for a
#                                deployment.
#   STORE_RECORDS                true or false. True: keep the image's record in the run's artifact store.
#   ADVISORY                     true or false. True: failed or undecided assertions exit 0.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/cli-stages.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/project.sh"

# The scanners whose reports the CLI reads.
readonly SCANNERS=(trivy grype)
# The CLI's stages record-image records: plan for a build, and the three
# stages of a deployment.
readonly STAGES=(plan pre_deploy post_deploy post_verify)

# Stops unless record-image records STAGE on the job's event.
check_stage_input() {
  check_stage_for_event record-image "the image" "$1" "${STAGES[@]}"
}

cmd_check() {
  local stage="$1"
  check_stage_input "${stage}"
  [[ -z "${ARTIFACT_NAME:-}" ]] || check_artifact_name "${ARTIFACT_NAME}"
  cli_path > /dev/null
}

# Stops unless the input INPUT, whose value is PATH_VALUE, names a file.
require_named_file() {
  local input="$1"
  local path_value="$2"
  [[ -f "${path_value}" ]] || die "The ${input} input names no file: '${path_value}'."
}

# Stops unless the input INPUT, whose value is VALUE, is given for STAGE.
require_input() {
  local input="$1"
  local value="$2"
  [[ -n "${value}" ]] || die "The ${input} input is required for stage ${STAGE}."
}

# Prints LINE without the spaces at its start and end.
trim() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  printf '%s\n' "${line%"${line##*[![:space:]]}"}"
}

# Adds the CLI option OPTION for the file the input INPUT names, when it names
# one, to ARGS. Each stage takes its own files; the CLI refuses a file option
# its stage does not take.
add_file_arg() {
  local input="$1"
  local option="$2"
  local path_value="$3"
  [[ -n "${path_value}" ]] || return 0
  require_named_file "${input}" "${path_value}"
  ARGS+=("${option}=${path_value}")
}

# Adds the CLI's options for the given files to ARGS.
add_file_args() {
  add_file_arg build-metadata --build-metadata "${BUILD_METADATA:-}"
  add_file_arg image-index --image-index "${IMAGE_INDEX:-}"
  add_file_arg attestation --attestation "${ATTESTATION:-}"
  local line
  while IFS= read -r line; do
    line="$(trim "${line}")"
    [[ -n "${line}" ]] || continue
    add_file_arg test-reports --test-report "${line}"
  done <<< "${TEST_REPORTS:-}"
  local scanner report
  while IFS= read -r line; do
    line="$(trim "${line}")"
    [[ -n "${line}" ]] || continue
    scanner="${line%% *}"
    report="$(trim "${line#* }")"
    [[ " ${SCANNERS[*]} " == *" ${scanner} "* && "${report}" != "${line}" && -n "${report}" ]] \
      || die "Each line of the scan-reports input must be a scanner (${SCANNERS[*]}), a space and the report's path. One line is '${line}'."
    require_named_file scan-reports "${report}"
    ARGS+=(--scanner="${scanner}" --scanner-report="${report}")
  done <<< "${SCAN_REPORTS:-}"
  add_file_arg workload-before-pods-listing --workload-before-pods-listing "${WORKLOAD_BEFORE_PODS_LISTING:-}"
  add_file_arg pods --pods "${PODS:-}"
  add_file_arg pod-owners --pod-owners "${POD_OWNERS:-}"
  add_file_arg workload-after-pods-listing --workload-after-pods-listing "${WORKLOAD_AFTER_PODS_LISTING:-}"
}

# Stops unless the inputs STAGE needs are given.
require_stage_inputs() {
  case "${STAGE}" in
    plan) require_input image "${IMAGE:-}" ;;
    pre_deploy | post_deploy)
      require_input image "${IMAGE:-}"
      require_input environment "${ENVIRONMENT:-}"
      ;;
    post_verify)
      require_input environment "${ENVIRONMENT:-}"
      require_input cluster-id "${CLUSTER_ID:-}"
      require_input workload-before-pods-listing "${WORKLOAD_BEFORE_PODS_LISTING:-}"
      require_input pods "${PODS:-}"
      require_input workload-after-pods-listing "${WORKLOAD_AFTER_PODS_LISTING:-}"
      ;;
    *) die "Unknown stage '${STAGE}'." ;;
  esac
}

cmd_run() {
  STAGE="$1"
  check_stage_input "${STAGE}"
  require_stage_inputs
  require_one_line image "${IMAGE:-}"
  require_one_line application "${APPLICATION:-}"
  # A deployment's records directory and artifact are named after its environment.
  if [[ "${STAGE}" == plan ]]; then
    require_one_line environment "${ENVIRONMENT:-}"
  else
    require_environment_name "${ENVIRONMENT:-}"
  fi
  require_one_line cluster-id "${CLUSTER_ID:-}"
  require_true_or_false advisory "${ADVISORY:-}"
  [[ -n "${UNIT:-}" ]] || die "The unit input is required."
  [[ "${UNIT}" =~ ${UNIT_NAME_PATTERN} ]] || die "Unit name '${UNIT}' does not follow the unit-name rule."
  local linked=false
  # A deployment is recorded only locally; the CLI refuses it in a linked project.
  if [[ "${STAGE}" == plan ]] && ! is_pull_request_event; then
    linked="$(project_linked)"
    # The CLI opens or joins the build run on the server with the job's identity token.
    [[ "${linked}" == false ]] || require_id_token
  fi
  set_server_args "${linked}"

  ARGS=()
  add_file_args

  # A build belongs to no environment; a deployment's records are kept apart
  # for each environment.
  local default_out="${RUNNER_TEMP}/iltero-image-records" default_artifact="iltero-image-records-${UNIT}"
  if [[ "${STAGE}" != plan ]]; then
    default_out="${RUNNER_TEMP}/iltero-image-deployment-records/${ENVIRONMENT}"
    default_artifact="iltero-image-deployment-records-${ENVIRONMENT}-${UNIT}"
  fi
  local artifact
  artifact="$(artifact_name "${ARTIFACT_NAME:-}" "${default_artifact}")"
  local work="${RUNNER_TEMP}/iltero-record-image/units/${UNIT}/${STAGE}"
  local out="${RECORDS_DIRECTORY:-${default_out}}"
  # A relative path starts with ./, so no command reads it as an option.
  [[ "${out}" == /* ]] || out="./${out}"
  rm -rf "${work}"
  mkdir -p "${out}" "${work}"
  # Absolute, because the upload step resolves paths from the repository root.
  out="$(cd "${out}" && pwd -P)"
  write_output records-directory "${out}"
  write_output artifact-name "${artifact}"

  [[ -z "${IMAGE:-}" ]] || ARGS+=(--image="${IMAGE}")
  [[ -z "${CLUSTER_ID:-}" ]] || ARGS+=(--cluster-id="${CLUSTER_ID}")
  [[ -z "${ENVIRONMENT:-}" ]] || ARGS+=(--environment="${ENVIRONMENT}")
  ARGS+=(--unit="${UNIT}" --out="${out}")
  local as_advice=false
  if is_pull_request_event; then
    # A pull request's image is checked locally, never recorded on the server,
    # and only as advice: a pull request check is never a merge gate.
    ARGS+=(--local --advisory)
    as_advice=true
  else
    [[ -z "${APPLICATION:-}" ]] || ARGS+=(--application="${APPLICATION}")
    # The CLI refuses --advisory at a stage, or in a run, that does not take it.
    [[ "${ADVISORY}" == false ]] || { ARGS+=(--advisory); as_advice=true; }
    ARGS+=(${SERVER_ARGS[@]+"${SERVER_ARGS[@]}"})
  fi
  local status=0
  check_change_stage image "${work}" "${STAGE}" "${ARGS[@]}" || status=$?

  local result="exit ${status}" details="${work}/details.md"
  # Checked as advice, exit 0 can hide failed or undecided assertions, so the
  # summary says the step checked as advice.
  [[ "${as_advice}" == false || "${status}" -ne 0 ]] || result+=", checked as advice: failed or undecided assertions do not fail the step"
  : > "${details}"
  append_details_block "${details}" "${UNIT}: image check, ${STAGE//_/-}" "${work}/${STAGE}.txt"
  {
    echo "## Iltero image record: $(markdown_escape "${UNIT}"), ${STAGE//_/-}"
    echo
    [[ -z "${IMAGE:-}" ]] || echo "Image: $(markdown_escape "${IMAGE}")."
    [[ -z "${ENVIRONMENT:-}" ]] || echo "Environment: $(markdown_escape "${ENVIRONMENT}")."
    echo "Result: ${result}."
    echo
    cat "${details}"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

  [[ "${status}" -eq 0 ]] || exit "${status}"
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) [[ $# -eq 1 ]] || die "Usage: image/record.sh check STAGE"; cmd_check "$@" ;;
    run) [[ $# -eq 1 ]] || die "Usage: image/record.sh run STAGE"; cmd_run "$@" ;;
    *) die "Unknown command '${command}'. Use: check STAGE | run STAGE" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
