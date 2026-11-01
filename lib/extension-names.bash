#!/usr/bin/env bash
# Canonical extension artifact naming:
#   source artifact: npass-NAME[.bash]
#   installed artifact: npass-NAME
#   runtime/list name: NAME
#
# Keep this parser shared by the installer and its tests. NAME is deliberately
# narrower than a path or shell identifier: lowercase ASCII and hyphens only.

npass_extension_name_valid() {
    [[ ${1-} =~ ^[a-z0-9][a-z0-9-]*$ && ${1-} != npass-* ]]
}

npass_extension_artifact_name() {
    local filename=${1##*/} name
    filename=${filename%.bash}
    [[ "$filename" == npass-* ]] || return 1
    name=${filename#npass-}
    npass_extension_name_valid "$name" || return 1
    printf '%s' "$name"
}
