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
cache_dir=/broad/hptmp/$USER
bind_autofs=false

usage() {
    cat >&2 <<EOF
USAGE: $progname [-c cache_dir] [-a] [-b singularity_mount] [-S singularity_arguments] docker_image docker_command [container_args...]
Run a singularity container

-c <cache_dir>         : Directory to cache downloaded docker images. Default: /broad/hptmp/$USER.
-a                     : Mount all existing autofs mounts into the container.
-b <singularity_mount> : Custom bind path spec in the format src[:dest[:opts]].
-s <singularity_args>  : A space separated string of arguments to pass to singularity. Default: "".
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

while getopts ":c:ab:s:h" options; do
  case $options in
    a) bind_autofs=true;;
    b) singularity_binds="$singularity_binds --bind $OPTARG";;
    c) cache_dir=$OPTARG;;
    s) singularity_args=$OPTARG;;
    h) usage
      exit 1;;
    *) usage
      exit 1;;
  esac
done
shift $((OPTIND - 1))

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

mkdir -p "$SINGULARITY_TMPDIR"

singularity_image=$cache_dir/$docker_name.sif
(
  flock --exclusive --timeout 3600 9 || exit 1
  if [ ! -e "$singularity_image" ]; then
    echo "INFO:    Image does not exist: $singularity_image..." >&2
    singularity build "$singularity_image" "docker://${docker_image}"
  fi
) 9>"$lock_file"

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
