#!/bin/bash

set -eo pipefail

PATCHLEVEL="4"

TEMP_REPO=$(mktemp -d)
sbt generateBuildCharacterPropertiesFile
BASE_VERSION=$(grep '^maven\.version\.base=' buildcharacter.properties | sed 's/.*=//')
HASH=$(grep '^version\.number=' buildcharacter.properties | sed 's/.*-//')
FULL_VERSION="$BASE_VERSION-bin-db-$PATCHLEVEL-$HASH"
echo "******************** Publishing $FULL_VERSION to $TEMP_REPO"
sbt -Dstarr.version=$BASE_VERSION "setupBootstrapQuick \"$TEMP_REPO\" \"$FULL_VERSION\" \"$TEMP_REPO\"; clean; library/publish; compiler/publish; reflect/publish"
echo "******************** Artifacts in $TEMP_REPO"
ls -lR $TEMP_REPO
echo "******************** Publishing $FULL_VERSION to S3"
(cd ~/universe; ./bazel/artifacts/resolver/publish.py --repo $TEMP_REPO "org.scala-lang:scala-library:$FULL_VERSION" "org.scala-lang:scala-compiler:$FULL_VERSION" "org.scala-lang:scala-reflect:$FULL_VERSION")

rm -rf $TEMP_REPO
