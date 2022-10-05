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
singularity_args=
singularity_binds=
cache_dir=/broad/hptmp/$USER/singularity
log_label_raw="$USER@$HOSTNAME"
bind_autofs=false
lock_timeout=3600

usage() {
    cat >&2 <<EOF
USAGE: $progname [-c cache_dir] [-a] [-b singularity_mount] [-S singularity_arguments] docker_image docker_command [container_args...]
Run a singularity container

-c <cache_dir>         : Directory to cache downloaded docker images. Default: /broad/hptmp/$USER/singularity.
-a                     : Mount all existing autofs mounts into the container.
-b <singularity_mount> : Custom bind path spec in the format src[:dest[:opts]].
-s <singularity_args>  : A space separated string of arguments to pass to singularity. Default: "".
-l <log_label>         : A label to use for logging. Default: "$USER@$HOSTNAME".
<docker_image>         : Hosted docker image to execute. Required.
<docker_command>       : Command to run on the docker image. Required.
<container_args>       : Additional arguments to pass to the singularity container.
-h                     : Show this help message.
EOF
}

make_autofs_binds() {
  # Do not mount /home, as users home directories often get searched for packages that are not in the container.
  mount | grep ^auto. | grep -v 'auto.home on /home' | awk '{print "--bind "$3":"$3":ro"}'
}

while getopts ":c:ab:s:l:h" options; do
  case $options in
    a) bind_autofs=true;;
    b) singularity_binds="$singularity_binds --bind $OPTARG";;
    c) cache_dir=$OPTARG;;
    s) singularity_args=$OPTARG;;
    l) log_label_raw=$OPTARG;;
    h) usage
      exit 1;;
    *) usage
      exit 1;;
  esac
done
shift $((OPTIND - 1))

log_label=$(eval echo "$log_label_raw")

docker_image=${1:-}
if [ -z "$docker_image" ]; then
    echo "No docker_image supplied." >&2
    usage
    exit 1;
fi
shift

docker_command=${1:-}
if [ -z "$docker_command" ]; then
    echo "No docker_command supplied." >&2
    usage
    exit 1;
fi
shift

mkdir -p "$cache_dir"

# Create a lock file for pulling images
lock_file=$cache_dir/singularity_pull_flock

# Change non alpha-numeric-ish characters to underscores
docker_name=${docker_image//[^A-Za-z0-9._-]/_}

export SINGULARITY_CACHEDIR=$cache_dir
export SINGULARITY_TMPDIR="$cache_dir/tmp"
build_log="$SINGULARITY_CACHEDIR/build.log"

log_msg() {
  printf '%s\n' "$1" >> "$build_log"
  printf '%s\n' "$1" >&2
}

mkdir -p "$SINGULARITY_TMPDIR"

singularity_image=$cache_dir/$docker_name.sif
if [ ! -e "$singularity_image" ]; then
  log_msg "INFO:    Image does not exist for $log_label at $(date): $singularity_image"
  log_msg "INFO:    Waiting up to $lock_timeout seconds for shared lock: $lock_file"
  log_msg "INFO:    View build logs at $build_log"
  (
      flock --exclusive --timeout "$lock_timeout" 9 || exit 1
      log_msg "INFO:    Lock acquired at $(date) for $log_label"
      if [ ! -e "$singularity_image" ]; then
        log_msg "INFO:    Building image for $log_label: $singularity_image"
        singularity build "$singularity_image.tmp" "docker://${docker_image}" >> "$build_log" 2>&1
        mv "$singularity_image.tmp" "$singularity_image"
      else
        log_msg "INFO:    Image now exists for $log_label: $singularity_image"
      fi
  ) 9>"$lock_file"
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
