#!/bin/bash
# Совместимая обёртка: sidecar-only режим полного установщика.
exec "$(cd "$(dirname "$0")" && pwd)/install-gigaam.sh" --sidecar "$@"
