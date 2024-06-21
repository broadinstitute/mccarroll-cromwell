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

# Pulls an image and runs a singularity container.

# This file is stored in source control here: https://github.com/broadinstitute/mccarroll-cromwell

set -euo pipefail

progname=$(basename "${BASH_SOURCE[0]}")
current_dir=$(dirname "${BASH_SOURCE[0]}")

# For folks in the dropseqgrp, cache the images in a shared location.
# Otherwise, cache them in a user-specific location.
# Known race condition: if two users build the same image at the same time, the
# second user will overwrite the first user's image possibly while the first user
# is still using it.
get_default_singularity_dir() {
  # Ignore errors from "groups" due to the grid engine group id.
  # https://github.com/rcgsheffield/sheffield_hpc/issues/686
  if { groups 2>/dev/null || true ; } | tr ' ' '\n' | grep -Fxq dropseqgrp; then
    echo "/broad/mccarroll/software/singularity"
  else
    echo "/broad/hptmp/$USER/singularity"
  fi
}

default_singularity_dir=$(get_default_singularity_dir)
default_log_label_raw="$USER@$HOSTNAME"
default_lock_timeout=$((90 * 60))

bind_autofs=
singularity_binds=
singularity_args=
singularity_dir=$default_singularity_dir
log_label_raw=$default_log_label_raw
lock_timeout=$default_lock_timeout

usage() {
  cat >&2 <<EOF
USAGE: $progname [-c singularity_dir] [-a] [-b singularity_mount] [-s singularity_arguments] [-l log_label] [-t lock_timeout] [-h] docker_image docker_command [container_args...]
Run a singularity container

-a                     : Mount all existing autofs mounts into the container as read-write.
-r                     : Mount all existing autofs mounts into the container as read-only.
-b <singularity_mount> : Custom bind path spec in the format src[:dest[:opts]].
-s <singularity_args>  : A space separated string of arguments to pass to singularity. Default: "".
-c <singularity_dir>   : Parent directory to download and cache docker images. Default: "$default_singularity_dir".
-l <log_label>         : A label to use for logging. Default: "$default_log_label_raw".
-t <lock_timeout>      : Timeout in seconds for acquiring a cache directory lock. Default: "$default_lock_timeout".
-h                     : Show this help message.
<docker_image>         : Hosted docker image to pull. Required.
<docker_command>       : Command to run on the docker image. Required.
<container_args>       : Additional arguments to pass to the singularity container.
EOF
}

make_autofs_binds() {
  mount_option=$1
  # Do not mount /home, as users home directories often get searched for packages that are not in the container.
  awk '$3 == "autofs" {print $2}' /etc/mtab \
  | grep -v '^/proc/' \
  | grep -v '^/home$' \
  | awk '{print "--bind "$1":"$1":'"$mount_option"'"}'
}

while getopts ":arb:s:c:l:t:h" options; do
  case $options in
    a) bind_autofs=rw;;
    r) bind_autofs=ro;;
    b) singularity_binds="$singularity_binds --bind $OPTARG";;
    s) singularity_args=$OPTARG;;
    c) singularity_dir=$OPTARG;;
    l) log_label_raw=$OPTARG;;
    t) lock_timeout=$OPTARG;;
    h) usage; exit 1;;
    *) usage; exit 1;;
  esac
done
shift $((OPTIND - 1))

docker_image=${1:-}
if [[ -z "$docker_image" ]]; then
  echo "No docker_image supplied." >&2
  usage
  exit 1
fi
shift 1

docker_command=${1:-}
if [[ -z "$docker_command" ]]; then
  echo "No docker_command supplied." >&2
  usage
  exit 1
fi
shift 1

# Change non alpha-numeric-ish characters to underscores
docker_name="${docker_image//[^A-Za-z0-9._-]/_}"

singularity_image="$singularity_dir/images/$docker_name.sif"

# shellcheck disable=SC2046
"$current_dir/pull_singularity.sh" \
  -o "$singularity_image" \
  -c "$singularity_dir" \
  -l "$log_label_raw" \
  -t "$lock_timeout" \
  "$docker_image"

# shellcheck disable=SC2046
# shellcheck disable=SC2086
singularity exec \
   --containall \
   --cleanenv \
   $(if [[ -n $bind_autofs ]]; then make_autofs_binds $bind_autofs; fi) \
   $singularity_binds \
   $singularity_args \
  "$singularity_image" \
  "$docker_command" \
  "$@"
