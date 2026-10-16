#!/bin/sh
# Builds misread-check: LifeKit's WordDiff + Misreads (../../../LifeKit) as the module LifeKit, then the check with the
# app's Claude Code session files. xcodebuild's Xcode if xcode-select points at the command line tools.
set -e
cd "$(dirname "$0")"
[ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode-beta.app ] && export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
LIFEKIT=../../../LifeKit/Sources/LifeKit
mkdir -p .build
xcrun swiftc -O -parse-as-library -module-name LifeKit -emit-module -emit-module-path .build/LifeKit.swiftmodule \
    -emit-library -static -o .build/libLifeKit.a "$LIFEKIT/WordDiff.swift" "$LIFEKIT/Misreads.swift"
xcrun swiftc -O -I .build -L .build -lLifeKit -o misread-check main.swift MisreadCandidates.swift MisreadJudge.swift \
    ../../MyType/AI/ClaudeCodeVoicePolishSession.swift ../../MyType/AI/ClaudeCodeHelpers.swift
