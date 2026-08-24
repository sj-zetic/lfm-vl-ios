#!/bin/sh
set -eu

ios_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$ios_dir/.." && pwd)
env_path=${1:-"$repo_dir/.env"}
output_path="$ios_dir/Secrets.xcconfig"
personal_key=""

write_config() {
    umask 077
    temporary_path=$(mktemp "$ios_dir/.Secrets.xcconfig.XXXXXX")
    trap 'rm -f "$temporary_path"' EXIT HUP INT TERM
    printf '%s\n' "// Generated from .env. Do not commit." "PERSONAL_KEY = $1" > "$temporary_path"
    chmod 600 "$temporary_path"
    mv "$temporary_path" "$output_path"
    trap - EXIT HUP INT TERM
}

if [ -f "$env_path" ]; then
    personal_key=$(awk -F= '$1 == "ZETIC_PERSONAL_KEY" { print substr($0, index($0, "=") + 1); exit }' "$env_path")
fi

case "$personal_key" in
    "" | "dev_YOUR_KEY_HERE")
        personal_key=""
        ;;
    *[!A-Za-z0-9._-]*)
        write_config ""
        echo "ZETIC_PERSONAL_KEY contains unsupported characters." >&2
        exit 1
        ;;
esac

write_config "$personal_key"
