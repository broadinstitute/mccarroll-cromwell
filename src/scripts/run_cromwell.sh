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
cloudsdk_auth_credentials_conf="${root_dir}/conf/cloudsdk_auth_credential.json"
logback_xml="${root_dir}/conf/logback.xml"

# Add Google-Cloud-SDK for docker-credential-gcloud.
# Add UGER for qsub.
set +eu
source /broad/software/scripts/useuse
unuse -q /broad/mccarroll/software/google-cloud-sdk
unuse -q UGER
use -q /broad/mccarroll/software/google-cloud-sdk
use -q UGER
set -eu

# This file is used via the gcloud cli environment variable CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE instead of
# GOOGLE_APPLICATION_CREDENTIALS.
#
# via: https://serverfault.com/questions/848580/how-to-use-google-application-credentials-with-gcloud-on-a-server
#
# NOTE: This config json file is the same as the adc json, but adds the field token_uri.
# Without it, gcloud complains that the service account json isn't valid.
if [ -f "$cloudsdk_auth_credentials_conf" ]; then
  # If the file is not mode 400, then exit with an error.
  if [ "$(stat -c %a "$cloudsdk_auth_credentials_conf")" -ne 400 ]; then
    echo "ERROR: $cloudsdk_auth_credentials_conf must be mode 400." >&2
    echo "Please run: chmod 400 $cloudsdk_auth_credentials_conf" >&2
    exit 1
  fi
  export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$cloudsdk_auth_credentials_conf"
  # Use the same conf as the application default credentials
  # since the Batch backend is using ADC credentials to dispatch jobs by not passing in creds
  # https://github.com/broadinstitute/cromwell/blob/90/supportedBackends/google/batch/src/main/scala/cromwell/backend/google/batch/GcpBatchBackendLifecycleActorFactory.scala#L103-L105
  export GOOGLE_APPLICATION_CREDENTIALS="$CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE"
fi

# Install SDKMAN via:
#   - https://sdkman.io/install
#   - export SDKMAN_DIR="<your_directory>" && curl -s "https://get.sdkman.io" | bash
export SDKMAN_DIR="/broad/mccarroll/software/sdkman"
set +u
source "$SDKMAN_DIR/bin/sdkman-init.sh"
sdk use java 21-tem
set -u

# enable job control so that kill -INT can be sent to java process
set -m
set -x
java \
  -Xmx4g \
  -Dconfig.file="$cromwell_conf" \
  -Dlogback.configurationFile="$logback_xml" \
  -jar "$cromwell_jar" \
  server &
set +x
set +m
