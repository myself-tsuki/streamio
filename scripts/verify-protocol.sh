#!/usr/bin/env bash
# Compiles the Foundation-only code (AMF0, RTMP chunking, FLV, audio ring buffer, scene models,
# canvas placement geometry)
# with any Swift 6.2+ toolchain (Linux works) and runs scripts/ProtocolChecks/main.swift.
set -euo pipefail
cd "$(dirname "$0")/../Streamio"
out="$(mktemp -d)/protocol-checks"
swiftc -swift-version 5 RTMP/AMF0.swift RTMP/RTMPChunker.swift RTMP/RTMPChunkReader.swift RTMP/RTMPMessage.swift \
  RTMP/RTMPEndpoint.swift RTMP/FLVTag.swift Audio/AudioRingBuffer.swift Models/AudioLevels.swift \
  Models/SceneSource.swift Models/VideoSource.swift Models/StudioScene.swift Models/FilterType.swift \
  Models/FilterParameters.swift Models/AudioSourceConfig.swift Models/AudioChannelID.swift \
  Models/StreamDestination.swift Models/StreamingService.swift Models/IngestServer.swift Metal/CanvasPlacement.swift \
  ../scripts/ProtocolChecks/LinuxShims.swift ../scripts/ProtocolChecks/main.swift -o "$out"
"$out"
