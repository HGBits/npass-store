#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/extension-names.bash"
}

@test "normaliza artefatos oficiais para nomes logicos sem duplicar npass-" {
    run npass_extension_artifact_name npass-audit
    [ "$status" -eq 0 ]
    [ "$output" = "audit" ]

    run npass_extension_artifact_name npass-clip-x11.bash
    [ "$status" -eq 0 ]
    [ "$output" = "clip-x11" ]

    run npass_extension_artifact_name npass-import
    [ "$status" -eq 0 ]
    [ "$output" = "import" ]

    run npass_extension_artifact_name npass-passkey
    [ "$status" -eq 0 ]
    [ "$output" = "passkey" ]

    run npass_extension_artifact_name npass-wclip.bash
    [ "$status" -eq 0 ]
    [ "$output" = "wclip" ]
}

@test "aceita nomes logicos apenas em lowercase ASCII com numeros e hifens internos" {
    run npass_extension_name_valid audit
    [ "$status" -eq 0 ]
    run npass_extension_name_valid clip-x11
    [ "$status" -eq 0 ]
    run npass_extension_name_valid a1-b2
    [ "$status" -eq 0 ]
}

@test "recusa prefixo ausente, prefixo duplicado e nomes malformados" {
    for artifact in audit npass- npass-npass-audit npass-Audit npass-audit_1 npass-audit.bash.bash npass-audit.extra npass-../escape; do
        run npass_extension_artifact_name "$artifact"
        [ "$status" -ne 0 ]
    done
}

@test "recusa nomes logicos com prefixo de artefato, caminho ou caracteres fora do contrato" {
    for name in npass-audit ../audit Audit audit_1 audit.bash ""; do
        run npass_extension_name_valid "$name"
        [ "$status" -ne 0 ]
    done
}
