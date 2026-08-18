# Harden the known upstream QuickShell Cava bridge without touching unrelated
# shell snippets.  This pass runs on Fedora's staging tree only; the source
# checkout and Arch deployment remain byte-for-byte unchanged.

function is_cava_script() {
    return FILENAME ~ /\/scripts\/cava[.]sh$/
}

{
    line=$0

    # The affected upstream line is intentionally matched as a complete
    # assignment.  Already guarded variants and other Cava versions are left
    # alone so repeated compatibility passes are byte-stable.
    if (!is_cava_script() ||
        line !~ /^[[:space:]]*CAVA_CONFIG[[:space:]]*=[[:space:]]*\$\(mktemp[[:space:]]+\/tmp\/cava-qs-XXXXXX[.]conf\)[[:space:]]*(#.*)?$/) {
        print line
        next
    }

    match(line, /^[[:space:]]*/)
    indent=substr(line, 1, RLENGTH)
    print indent "if ! CAVA_CONFIG=$(mktemp \"${TMPDIR:-/tmp}/cava-qs-XXXXXX.conf\") || [ -z \"$CAVA_CONFIG\" ]; then"
    print indent "    printf '%s\\n' 'ERROR: mktemp failed: unable to create temporary Cava config' >&2"
    print indent "    exit 1"
    print indent "fi"
}
