#!/bin/bash
#
# The CLI's report of a record, for a person to read. Source this file after
# common.sh.

# The files `iltero record report --format FORMAT --out DIR` writes in DIR.
readonly REPORT_HTML_FILE="record-report.html"
readonly REPORT_MARKDOWN_FILE="record-report.md"
# The most bytes of details a report may bring the job summary to. GitHub
# drops a step's whole summary above 1 MiB; this leaves room for the rest.
readonly REPORT_SUMMARY_MAX_BYTES=800000

# Prints WRITE_REPORT. Stops the job unless it is true or false.
report_enabled() {
  [[ "${WRITE_REPORT:-}" == true || "${WRITE_REPORT:-}" == false ]] \
    || die "The write-report input must be true or false, not '${WRITE_REPORT:-}'."
  echo "${WRITE_REPORT}"
}

# Has the CLI write a report of the record or record bundle at TARGET, as an
# HTML page and as Markdown, into REPORT_DIR/NAME. Appends the Markdown to
# DETAILS as a collapsed section, or a pointer to the artifact when it would
# make DETAILS too long for the job summary. The report exits with the record's
# verification code: a code other than 0 is only a warning. Returns 1 when the
# CLI did not write both files, so the caller fails the job.
write_report() {
  local name="$1"
  local target="$2"
  local report_dir="$3"
  local details="$4"
  local log="$5"
  local dir="${report_dir}/${name}" cli status=0 format
  cli="$(cli_path)"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  : > "${log}"
  for format in html markdown; do
    "${cli}" record report "${target}" --format="${format}" --out="${dir}" >> "${log}" 2>&1 || status=$?
  done
  print_untrusted "${log}"
  [[ "${status}" -eq 0 ]] || echo "::warning::The CLI's report of unit '${name}' exited with ${status}. See its output in the log."
  local file
  for file in "${REPORT_HTML_FILE}" "${REPORT_MARKDOWN_FILE}"; do
    if [[ ! -f "${dir}/${file}" ]]; then
      echo "::error::The CLI wrote no ${file} for unit '${name}'."
      return 1
    fi
  done
  touch "${details}"
  local size
  size=$(($(wc -c < "${details}") + $(wc -c < "${dir}/${REPORT_MARKDOWN_FILE}")))
  if [[ "${size}" -gt "${REPORT_SUMMARY_MAX_BYTES}" ]]; then
    printf '\nThe report of unit %s is too long for the job summary. It is in the report artifact.\n' "${name}" >> "${details}"
    return 0
  fi
  {
    echo "<details><summary>${name}: report</summary>"
    echo
    cat "${dir}/${REPORT_MARKDOWN_FILE}"
    echo
    echo "</details>"
  } >> "${details}"
}
