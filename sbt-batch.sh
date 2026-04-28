#!/bin/bash
exec sbt -J-Xmx6G -J-Xss4M -Dsbt.override.build.repos=true "$@"
