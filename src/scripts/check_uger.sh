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

# Checks to see if a job is still running in UGER.
# Has two primary advantages over a normal call to `qstat`:
#  - Caches results for multiple jobs so may be called hundreds of times per minute without overloading the server.
#  - Returns zero if it is unable to determine the status of the job due to an underlying issue.

# This file is stored in source control here: https://github.com/broadinstitute/mccarroll-cromwell

# NOTE: This script uses multiple return statements as `set -e` doesn't always exit.
# http://stratus3d.com/blog/2019/11/29/bash-errexit-inconsistency/
set -euo pipefail

job_id="${1?no job id specified}"

cache_dir="/broad/hptmp/${USER}/check_uger_cache"
mkdir -p "$cache_dir"

running_file="$cache_dir/running.txt"
cache_lock="$cache_dir/lock"
cache_ttl_seconds=60

log_msg() {
  printf '%s - %s\n' "$(date)" "$1" >&2
}

is_cache_stale() {
  local date_cache
  local date_now
  local date_diff
  if [[ -e "$running_file" ]]; then
    date_cache=$(date +%s -r "$running_file")
    date_now=$(date +%s)
    date_diff=$((date_now - date_cache))
    test $date_diff -gt $cache_ttl_seconds || return 1
  fi
}

invalidate_cache() {
  touch -m --date=@0 "$running_file"
}

# Attempt to refresh the cache.
try_refresh_cache() {
  local temp_file
  (
    temp_file="$(mktemp "$running_file.XXXXXXXXX")"
    if qstat | tail -n +3 | awk '{print $1}' > "$temp_file"; then
      mv "$temp_file" "$running_file"
    else
      log_msg "Problem with cache refresh. Try again later."
      touch "$running_file"
      return 1
    fi
  ) || return 1
}

# Refresh the cache if it is stale.
maybe_refresh_cache() {
  if is_cache_stale; then
     (
       flock --exclusive --timeout 60 9 || return 1
       if is_cache_stale; then
         log_msg "Cache is stale refreshing."
         try_refresh_cache || return 1
       fi
     ) 9>"$cache_lock" || return 1
  fi
}

# Check if the job is either in the cache or the cache is having problems and should be tried later.
check_job_cache() {
  # If we can't refresh the cache assume everything is ok for now and try later.
  if maybe_refresh_cache; then
    if grep -q "^$job_id$" "$running_file"; then
      log_msg "Job ${job_id} found in cache."
    else
      log_msg "Job ${job_id} not found in cache."
      return 1
    fi
  fi
}

# Check on the job immediately invalidating the cache if it
check_job_immediate() {
  local qstat_rc
  local qstat_stderr
  qstat_rc=0
  qstat_stderr="$cache_dir/qstat_$job_id"
  qstat -j "$job_id" 1>/dev/null 2>"$qstat_stderr" || qstat_rc=$?
  if [[ $qstat_rc -eq 0 ]]; then
    log_msg "Job ${job_id} found in qstat. Invalidating cache."
    # Since qstat found the job then make the cache stale.
    invalidate_cache
  elif grep -q "jobs do not exist" "$qstat_stderr"; then
    log_msg "Job ${job_id} not found in qstat."
    # qstat can error for a number of reasons. So we're not looking for the exit code. Instead we're
    # looking for an affirmative message that the job is no longer being tracked. This will be in
    # the stderr so use file descriptors to grep ONLY the stderr, not the stdout.
    # h/t: https://unix.stackexchange.com/questions/3514/how-to-grep-standard-error-stream-stderr#answer-3540
    return 1
  else
    log_msg "qstat returned $qstat_rc. Try again later. qstat stderr contained:"
    cat "$qstat_stderr" >&2
  fi
}

if ! check_job_cache; then
  check_job_immediate
fi
