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

# Run the specified application with custom commands.
# Sourced and monitored by the loop_<app>.sh sibling script.
# Start and stop the app using start_<app>.sh and stop_<app>.sh.

# This file is stored in source control here: https://github.com/broadinstitute/mccarroll-cromwell

set -euo pipefail

cd "$(dirname "$0")/.."
root_dir=$(pwd)
cromwell_jar="${root_dir}/bin/cromwell.jar"
cromwell_conf="${root_dir}/conf/cromwell.conf"

# Add Google-Cloud-SDK for docker-credential-gcloud.
set +eu
source /broad/software/scripts/useuse
unuse -q Google-Cloud-SDK
use -q Google-Cloud-SDK
set -eu

# Install SDKMAN via:
#   - https://sdkman.io/install
#   - export SDKMAN_DIR="<your_directory>" && curl -s "https://get.sdkman.io" | bash
export SDKMAN_DIR="/broad/mccarroll/software/sdkman"
set +u
source "$SDKMAN_DIR/bin/sdkman-init.sh"
sdk use java 11.0.15-tem
set -u

# enable job control so that kill -INT can be sent to java process
set -m
set -x
java \
  -Xmx2g \
  -Dconfig.file="$cromwell_conf" \
  -jar "$cromwell_jar" \
  server &
set +x
set +m
