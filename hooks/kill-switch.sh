#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# Halt every tool call while AGENT_STOP exists. `touch AGENT_STOP` to engage; `rm AGENT_STOP` to resume.
#
# AI Heroes addition (0.4.0): default to ${WORKDIR:-$PWD}/AGENT_STOP instead
# of plain ./AGENT_STOP so the path matches what heartbeat-stop.sh inspects
# even when the agent is running in a subdirectory. Bug D1 in
# docs/parity-gap-analysis.md.
if [ -e "${AGENT_STOP_FILE:-${WORKDIR:-$PWD}/AGENT_STOP}" ]; then
  cat <<'JSON'
{"decision":"block","reason":"Kill switch engaged: AGENT_STOP file exists. Agent is halted. Remove the file to resume."}
JSON
fi
