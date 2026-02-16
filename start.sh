#!/bin/bash
cd "$(dirname "$0")"
swift build -q 2>&1 && .build/debug/Ligma
