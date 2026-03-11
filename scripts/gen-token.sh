#!/usr/bin/env bash
set -euo pipefail
token=$(openssl rand -hex 32)
echo "API_TOKEN=$token"
