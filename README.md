# McCarroll Cromwell

## Overview

Scripts, configuration, and code contributions used to run the McCarroll Lab's Cromwell instance.

This Cromwell instance supports running Docker/Singularity containers on either the Broad UGER
cluster or Google Cloud.

## Contents

### `src/scripts`

Custom scripts for launching and monitoring the McCarroll Cromwell server and jobs.

### `src/conf`

The McCarroll Cromwell configuration files minus any secrets.

### `cromwell`

A submodule pointing to the custom branch of
[broadinstitute/cromwell](https://github.com/broadinstitute/cromwell) running on the McCarroll
Cromwell instance. Often this branch will contain comments ahead of the `develop` branch with added
features under review by the Cromwell developers.

NOTE: Unlike changes merged to the upstream `develop` branch changes in this submodule should be
considered experimental and used with care!
