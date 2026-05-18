#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
pkill -f "$DIR/ChargeLimit" 2>/dev/null
echo "ChargeLimit stopped"
