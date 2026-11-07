#!/usr/bin/env bash
# Fails when a log contains a warning or a deprecation notice; the repository tolerates no warnings (see
# CONTRIBUTING.md).
#
# Usage:
#   script/warning_gate.sh            checks the logs of every other job of the current workflow run (the "Warning
#                                     gate" job of every workflow). Needs GH_TOKEN (actions: read),
#                                     GITHUB_REPOSITORY, GITHUB_RUN_ID and GATE_JOB_NAME (the name of the gate job
#                                     itself, whose own log quotes the findings).
#   script/warning_gate.sh LOG...     checks the given log files (script/check, on the output of every check).
set -euo pipefail

pattern='[Ww]arning:|WARNING:|DEPRECATION|DEPRECATED|##\[warning\]'
pattern+='|is deprecated|will be deprecated|Node\.js [0-9]+ actions are deprecated'
# The one kind of matching line that is not a warning: CodeQL prints the JSON schema of its extractor options,
# whose "title" and "description" fields document a deprecated option ("DEPRECATED - Whether to use
# buildless ..."). Only such JSON documentation fields are skipped; the same words anywhere else still fail.
documentation='^[0-9TZ:.-]+ +"(title|description)" : "'

# The other kind: the OpenSSF Scorecard action prints the event payload of the run, which carries the message of
# every pushed commit, so a commit titled "...catch Warning: lines..." would match. Only a `"message": "` field that
# starts with the title of one of this run's own commits (from GITHUB_EVENT_PATH) is skipped.
titles=()
if [[ -n ${GITHUB_EVENT_PATH:-} && -f ${GITHUB_EVENT_PATH} ]]; then
  commit_titles=$(jq -r '[.commits[]?.message, .head_commit.message?] | map(select(. != null) | split("\n")[0])
    | .[]' "${GITHUB_EVENT_PATH}")
  while IFS= read -r title; do
    [[ -n ${title} ]] && titles+=("${title}")
  done <<<"${commit_titles}"
fi

# Drops the lines (read from standard input) that echo one of this run's commit titles.
without_commit_messages() {
  local line title echoed
  while IFS= read -r line; do
    echoed=false
    for title in "${titles[@]+"${titles[@]}"}"; do
      [[ ${line} == *"\"message\": \"${title}"* ]] && echoed=true
    done
    if [[ ${echoed} == false && -n ${line} ]]; then
      printf '%s\n' "${line}"
    fi
  done
}

# Prints the warnings of a log (read from standard input), each with its line number.
warnings() {
  local hits
  hits=$(grep -nE -e "${pattern}" | grep -vE -e "^[0-9]+:${documentation#^}" || true)
  without_commit_messages <<<"${hits}"
}

# Prints the result for one log and records a failure in `status`.
status=0
judge() {
  local name=$1 hits=$2
  if [[ -n ${hits} ]]; then
    printf '::error::Warnings in the log of %s\n%s\n\n' "${name}" "${hits}"
    status=1
  else
    printf 'No warnings in the log of %s\n' "${name}"
  fi
}

if [[ $# -gt 0 ]]; then
  for log in "$@"; do
    hits=$(warnings <"${log}")
    judge "${log}" "${hits}"
  done
  exit "${status}"
fi

: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}" "${GATE_JOB_NAME:?}"
# The other jobs that ran to completion (in the release workflow, the jobs after the gate are still waiting).
others=".jobs[] | select(.name != \"${GATE_JOB_NAME}\" and .status == \"completed\" and .conclusion != \"skipped\")"
jobs=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs?per_page=100" \
  --jq "${others} | \"\(.id)\t\(.name)\"")

while IFS=$'\t' read -r id name; do
  [[ -n ${id} ]] || continue
  # Downloaded with curl: depending on its version, gh refuses to print a log that contains terminal escape
  # sequences (colored tool output), and older versions do not know the flag that allows them.
  log=$(curl --fail --silent --show-error --location \
    --header "Authorization: Bearer ${GH_TOKEN}" --header 'Accept: application/vnd.github+json' \
    "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/actions/jobs/${id}/logs")
  hits=$(warnings <<<"${log}")
  judge "job \"${name}\"" "${hits}"
done <<<"${jobs}"

exit "${status}"
