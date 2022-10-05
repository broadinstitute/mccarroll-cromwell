#!/bin/bash

# MIT License
#
# Copyright 2022 Broad Institute
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Submits jobs to UGER.
# Has two primary advantages over a normal call to `qsub`:
#  - Submits with a jitter, so all jobs don't submit at the same time.
#  - Retries errors with an exponential backoff.

# This file is stored in source control here: https://github.com/broadinstitute/mccarroll-cromwell

set -euo pipefail

log_msg() {
  printf '%s - %s\n' "$(date)" "$1" >&2
}

submit_jitter=$(( ( RANDOM % 15 )  + 1 ))
sleep_secs=30
attempts=3

sleep $submit_jitter

for attempt in $(seq 1 $attempts); do

  set +e
  qsub "$@"
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    exit $rc
  fi

  log_msg "Failed qsub attempt $attempt..."
  if [[ $attempt -ge $attempts ]]; then
    log_msg "Giving up."
    exit $rc
  else
    log_msg "Sleeping $sleep_secs seconds..."
    sleep $sleep_secs
    sleep_secs=$((sleep_secs * 2))
  fi

done
