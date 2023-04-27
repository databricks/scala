#!/bin/bash

set -eo pipefail

PATCHLEVEL="1"

TEMP_REPO=$(mktemp -d)
sbt generateBuildCharacterPropertiesFile
BASE_VERSION=$(grep '^maven\.version\.base=' buildcharacter.properties | sed 's/.*=//')
HASH=$(grep '^version\.number=' buildcharacter.properties | sed 's/.*-//')
FULL_VERSION="$BASE_VERSION-bin-db-$PATCHLEVEL-$HASH"
echo "******************** Publishing $FULL_VERSION to $TEMP_REPO"
sbt "setupBootstrapQuick \"$TEMP_REPO\" \"$FULL_VERSION\" \"$TEMP_REPO\"; clean; library/publish"
echo "******************** Artifacts in $TEMP_REPO"
ls -lR $TEMP_REPO
echo "******************** Publishing $FULL_VERSION to S3"
(cd ~/universe; ./bazel/artifacts/resolver/publish.py --repo $TEMP_REPO "org.scala-lang:scala-library:$FULL_VERSION")

rm -rf $TEMP_REPO
