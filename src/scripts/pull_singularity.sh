#!/bin/bash

# MIT License
#
# Copyright 2023 Broad Institute
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

# Pulls a singularity image.

# This file is stored in source control here: https://github.com/broadinstitute/mccarroll-cromwell

set -euo pipefail

progname=$(basename "${BASH_SOURCE[0]}")

default_cache_dir_user="/broad/hptmp/$USER/singularity"
default_cache_dir_dropseqgrp="/broad/mccarroll/software/singularity"

# For folks in the dropseqgrp, cache the images in a shared location.
# Otherwise, cache them in a user-specific location.
# Known race condition: if two users build the same image at the same time, the
# second user will overwrite the first user's image possibly while the first user
# is still using it.
get_default_cache_dir() {
  # Ignore errors from "groups" due to the grid engine group id.
  # https://github.com/rcgsheffield/sheffield_hpc/issues/686
  if { groups 2>/dev/null || true ; } | tr ' ' '\n' | grep -Fxq dropseqgrp; then
    echo "$default_cache_dir_dropseqgrp"
  else
    echo "$default_cache_dir_user"
  fi
}

default_cache_dir=$(get_default_cache_dir)
default_log_label_raw="$USER@$HOSTNAME"
default_lock_timeout=$((90 * 60))

singularity_image=
cache_dir=$default_cache_dir
log_label_raw=$default_log_label_raw
lock_timeout=$default_lock_timeout
force_build=false

usage() {
  cat >&2 <<EOF
USAGE: $progname [-o singularity_image] [-c cache_dir] [-l log_label] [-t lock_timeout] [-f] [-h] docker_image
Pull a singularity container

-o <singularity_image> : Path to the singularity image to create. Default: "<cache_dir>/<docker_image>.sif"
-c <cache_dir>         : Directory to cache downloaded docker images. Default: "$default_cache_dir".
-l <log_label>         : A label to use for logging. Default: "$default_log_label_raw".
-t <lock_timeout>      : Timeout in seconds for acquiring a cache directory lock. Default: "$default_lock_timeout".
-f                     : Force a rebuild of the singularity image file.
-h                     : Show this help message.
<docker_image>         : Hosted docker image to execute. Required.
EOF
}

while getopts ":o:c:l:t:fh" options; do
  case $options in
    o) singularity_image=$OPTARG;;
    c) cache_dir=$OPTARG;;
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
shift 1

# Ensure the images for the dropseqgrp are shared.
if [[ "$cache_dir" == "$default_cache_dir_dropseqgrp" ]]; then
  # The images may be shared, singularity cannot stop that.
  image_dir=$default_cache_dir_dropseqgrp
  # However, the directory for caching blobs must contain a directory ONLY owned by the user,
  # which will be forcefully set to chmod 700. This limitation is forced by this code block:
  # https://github.com/sylabs/singularity/commit/2cda4981812c29f0fb11d3ea6aaf6139f665a631#diff-759d5ff855d91f9b3f1fad705a86e1e5a50733cc9103dee5084b611647ed5d7fR303-R314
  blob_dir=$default_cache_dir_dropseqgrp/caches/$USER
  # Temporary files that aren't reused bas still be written elsewhere.
  tmp_dir=$default_cache_dir_user/tmp
else
  image_dir=$cache_dir
  blob_dir=$cache_dir
  tmp_dir=$cache_dir/tmp
fi

if [[ -z "$singularity_image" ]]; then
  # Change non alpha-numeric-ish characters to underscores
  docker_name=${docker_image//[^A-Za-z0-9._-]/_}

  singularity_image="$image_dir/$docker_name.sif"
fi

# Create a lock file for building images.
cache_lock="$blob_dir/cache.lock"

# Write the build logs to a shared file.
build_log="$image_dir/build.log"

# Ensure two processes don't try to write to the build log at the same time.
build_log_lock="${build_log}.lock"

mk_cache_dirs() {
  mkdir -p "$image_dir"
  mkdir -p "$blob_dir"
  mkdir -p "$tmp_dir"
}

log_msg() {
  printf '%s\n' "$@" >&2
  # Known race condition: This lock reduces collisions. However, later we do NOT use the log lock during the
  # "singularity build". Thus two users could try to write-append to the log at the same time.
  (
    flock --exclusive --timeout 30 9
    printf '%s\n' "$@" >> "$build_log"
  ) 9>"$build_log_lock"
}

pull_image() {
  if [[ $(realpath "$(which singularity)") == */apptainer ]]; then
    # Apptainer emits warnings if it finds the SINGULARITY_TMPDIR variable.
    export APPTAINER_CACHEDIR=$blob_dir
    export SINGULARITY_CACHEDIR=$blob_dir
    export APPTAINER_TMPDIR=$tmp_dir
  else
    export SINGULARITY_CACHEDIR=$blob_dir
    export SINGULARITY_TMPDIR=$tmp_dir
  fi

  log_msg "INFO:    $log_label waiting for lock up to $lock_timeout seconds from $(date)"
  printf "INFO:    View build logs at %s\n" "$build_log" >&2
  (
    exit_script=false

    function ctrl_c() {
      exit_script=true
    }

    # If the user hits Ctrl-C, do not retry and exit the script.
    trap ctrl_c INT

    flock --exclusive --timeout "$lock_timeout" 9

    log_msg "INFO:    $log_label acquired lock at $(date)"

    if [[ ! -e "$singularity_image" ]] || [[ "$force_build" == true ]]; then
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

        if [[ $exit_script == true ]]; then
          exit $rc
        fi

        error_prefix="ERROR:   $log_label failed build during attempt $attempt at $(date) with result $rc"
        if [[ $attempt -lt $attempts ]]; then
          log_msg "$error_prefix ... Retrying."
        else
          log_msg "$error_prefix ... Giving up."
          exit $rc
        fi

      done

      mv "$singularity_image.tmp" "$singularity_image"

      # Undo singularity's chmod 700 mentioned above, ensuring the caches may be cleaned up by the dropseqgrp.
      if [[ "$cache_dir" == "$default_cache_dir_dropseqgrp" ]]; then
        chgrp -R dropseqgrp "$blob_dir"
        chmod -R ug+rwX,o-rwx "$blob_dir"
      fi

      # Ensure the images for the dropseqgrp are shared.
      if [[ "$(dirname "$singularity_image")" == "$default_cache_dir_dropseqgrp" ]]; then
        chgrp -R dropseqgrp "$singularity_image"
        chmod -R ug+rwX,o-rwx "$singularity_image"
      fi
    fi
  ) 9>"$cache_lock"
  log_msg "INFO:    Image now exists for $log_label at $(date): $singularity_image"
}

if [[ ! -e "$singularity_image" ]]; then
  mk_cache_dirs
  log_msg "INFO:    Image does not exist for $log_label at $(date): $singularity_image"
  pull_image
elif [[ "$force_build" == true ]]; then
  mk_cache_dirs
  pull_image
fi
