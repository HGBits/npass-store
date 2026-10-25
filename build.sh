#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

out="bin/npass"
mkdir -p "$(dirname "$out")"
{
	echo '#!/usr/bin/env bash'
	echo '# GENERATED FILE - built by build.sh from lib/*.bash. Do not edit directly.'
	for f in lib/*.bash; do
		[[ "$f" == "lib/00-main.bash" ]] && continue
		tail -n +2 "$f"
		echo
	done
	tail -n +2 lib/00-main.bash
} >"$out"
chmod +x "$out"
echo "built: $out"
