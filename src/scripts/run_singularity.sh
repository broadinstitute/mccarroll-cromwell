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

# Pulls and runs a singularity container.

# This file is stored in source control here: https://github.com/broadinstitute/mccarroll-cromwell

set -euo pipefail

progname=$(basename "$0")

default_cache_dir=/broad/hptmp/$USER/singularity
default_log_label_raw="$USER@$HOSTNAME"
default_lock_timeout=$((90 * 60))

singularity_args=
bind_autofs=false
singularity_binds=
cache_dir=$default_cache_dir
log_label_raw=$default_log_label_raw
lock_timeout=$default_lock_timeout
force_build=false

usage() {
    cat >&2 <<EOF
USAGE: $progname [-c cache_dir] [-a] [-b singularity_mount] [-s singularity_arguments] [-l log_label] [-t lock_timeout] [-f] docker_image docker_command [container_args...]
Run a singularity container

-c <cache_dir>         : Directory to cache downloaded docker images. Default: $default_cache_dir.
-a                     : Mount all existing autofs mounts into the container.
-b <singularity_mount> : Custom bind path spec in the format src[:dest[:opts]].
-s <singularity_args>  : A space separated string of arguments to pass to singularity. Default: "".
-l <log_label>         : A label to use for logging. Default: "$default_log_label_raw".
-t <lock_timeout>      : Timeout in seconds for acquiring a lock on the cache directory. Default: $default_lock_timeout.
-f                     : Force a rebuild of the container.
<docker_image>         : Hosted docker image to execute. Required.
<docker_command>       : Command to run on the docker image. Required.
<container_args>       : Additional arguments to pass to the singularity container.
-h                     : Show this help message.
EOF
}

make_autofs_binds() {
  # Do not mount /home, as users home directories often get searched for packages that are not in the container.
  awk '$3 == "autofs" {print $2}' /etc/mtab \
  | grep -v '^/proc/' \
  | grep -v '^/home$' \
  | awk '{print "--bind "$1":"$1":ro"}'
}

while getopts ":c:ab:s:l:t:fh" options; do
  case $options in
    a) bind_autofs=true;;
    b) singularity_binds="$singularity_binds --bind $OPTARG";;
    c) cache_dir=$OPTARG;;
    s) singularity_args=$OPTARG;;
    l) log_label_raw=$OPTARG;;
    t) lock_timeout=$OPTARG;;
    f) force_build=true;;
    h) usage; exit 1;;
    *) usage; exit 1;;
  esac
done
shift $((OPTIND - 1))

log_label=$(eval echo "$log_label_raw")

docker_image=${1:-}
if [[ -z "$docker_image" ]]; then
    echo "No docker_image supplied." >&2
    usage
    exit 1
fi
shift

docker_command=${1:-}
if [[ -z "$docker_command" ]]; then
    echo "No docker_command supplied." >&2
    usage
    exit 1
fi
shift

mkdir -p "$cache_dir/tmp"

# Create a lock file for pulling images
lock_file=$cache_dir/singularity_pull_flock

# Change non alpha-numeric-ish characters to underscores
docker_name=${docker_image//[^A-Za-z0-9._-]/_}

# Write the build logs to a shared file
build_log="$cache_dir/build.log"

if [[ $(realpath "$(which singularity)") == */apptainer ]]; then
  # Apptainer emits warnings if it finds the SINGULARITY_TMPDIR variable.
  export APPTAINER_CACHEDIR=$cache_dir
  export APPTAINER_TMPDIR=$cache_dir/tmp
  export SINGULARITY_CACHEDIR=$cache_dir
else
  export SINGULARITY_CACHEDIR=$cache_dir
  export SINGULARITY_TMPDIR=$cache_dir/tmp
fi

log_msg() {
  printf '%s\n' "$1" >> "$build_log"
  printf '%s\n' "$1" >&2
}

pull_image() {
  log_msg "INFO:    $log_label waiting for lock up to $lock_timeout seconds from $(date)"
  printf "INFO:    View build logs at %s\n" "$build_log" >&2
  (
      flock --exclusive --timeout "$lock_timeout" 9
      log_msg "INFO:    $log_label acquired lock at $(date)"
      if [[ ! -e "$singularity_image" ]] || [[ "$force_build" = true ]]; then
        log_msg "INFO:    $log_label building image: $singularity_image"

        # Use retries to avoid transient errors such as:
        # ```
        # FATAL:   While performing build: while creating squashfs: create command failed:
        # exit status 1: writer: Lseek on destination failed because Bad file descriptor,
        # offset=0x1c45bd7
        # FATAL ERROR:Probably out of space on output filesystem
        # ```
        attempts=3
        for attempt in $(seq 1 $attempts); do

          set +e
          singularity build --force "$singularity_image.tmp" "docker://${docker_image}" \
            >> "$build_log" 2>&1
          rc=$?
          set -e

          if [[ $rc -eq 0 ]]; then
            break
          fi

          error_prefix="ERROR:   $log_label failed build during attempt $attempt at $(date)"
          if [[ $attempt -lt $attempts ]]; then
            log_msg "$error_prefix ... Retrying."
          else
            log_msg "$error_prefix ... Giving up."
            exit $rc
          fi

        done

        mv "$singularity_image.tmp" "$singularity_image"
      fi
  ) 9>"$lock_file"
  log_msg "INFO:    Image now exists for $log_label at $(date): $singularity_image"
}

singularity_image=$cache_dir/$docker_name.sif
if [[ ! -e "$singularity_image" ]]; then
  log_msg "INFO:    Image does not exist for $log_label at $(date): $singularity_image"
  pull_image
elif [[ "$force_build" = true ]]; then
  pull_image
fi

# shellcheck disable=SC2046
# shellcheck disable=SC2086
singularity exec \
   --containall \
   --cleanenv \
   $(if [[ $bind_autofs == true ]]; then make_autofs_binds; fi) \
   $singularity_binds \
   $singularity_args \
  "$singularity_image" \
  "$docker_command" \
  "$@"
