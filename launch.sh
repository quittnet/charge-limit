#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if [ ! -f ChargeLimit ] || [ ChargeLimit.swift -nt ChargeLimit ]; then
    swiftc ChargeLimit.swift -o ChargeLimit -framework AppKit -framework SwiftUI
fi

pkill -f "$DIR/ChargeLimit" 2>/dev/null || true
sleep 0.5
nohup "$DIR/ChargeLimit" > "$DIR/ChargeLimit.log" 2>&1 &
echo "ChargeLimit launched (pid $!)"
