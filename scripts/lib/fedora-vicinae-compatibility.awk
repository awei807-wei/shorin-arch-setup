# Fedora's Vicinae provider installs the verified AppImage as
# ~/.local/bin/vicinae.AppImage.  Transform only the exact server/toggle
# invocations owned by the Niri config/binds contract; unrelated commands and
# comments remain byte-for-byte unchanged.

BEGIN {
    if (mode != "server" && mode != "toggle") exit 2
}

function split_comment(line,    i, c, next_char, quoted, escaped) {
    code = line
    comment = ""
    quoted = 0
    escaped = 0
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        next_char = substr(line, i + 1, 1)
        if (quoted) {
            if (escaped) {
                escaped = 0
            } else if (c == "\\") {
                escaped = 1
            } else if (c == "\"") {
                quoted = 0
            }
            continue
        }
        if (c == "\"") {
            quoted = 1
        } else if (c == "/" && next_char == "/") {
            code = substr(line, 1, i - 1)
            comment = substr(line, i)
            return
        }
    }
}

function target_present(value) {
    if (mode == "server") {
        return value ~ /"vicinae"[[:space:]]+"server"/ ||
            value ~ /"vicinae[.]AppImage"[[:space:]]+"server"/ ||
            value ~ /\\"vicinae\\"[[:space:]]+\\"server\\"/ ||
            value ~ /\\"vicinae[.]AppImage\\"[[:space:]]+\\"server\\"/ ||
            value ~ /"vicinae[[:space:]]+server"/ ||
            value ~ /"vicinae[.]AppImage[[:space:]]+server"/ ||
            value ~ /\(vicinae[[:space:]]+server\)/ ||
            value ~ /\(vicinae[.]AppImage[[:space:]]+server\)/
    }
    return value ~ /"vicinae"[[:space:]]+"toggle"/ ||
        value ~ /"vicinae[.]AppImage"[[:space:]]+"toggle"/ ||
        value ~ /\\"vicinae\\"[[:space:]]+\\"toggle\\"/ ||
        value ~ /\\"vicinae[.]AppImage\\"[[:space:]]+\\"toggle\\"/ ||
        value ~ /"vicinae[[:space:]]+toggle"/ ||
        value ~ /"vicinae[.]AppImage[[:space:]]+toggle"/ ||
        value ~ /\(vicinae[[:space:]]+toggle\)/ ||
        value ~ /\(vicinae[.]AppImage[[:space:]]+toggle\)/
}

function convert(value) {
    # The guard is part of the same exact target line in the Fedora fixture.
    # The target check above prevents similar command names from being edited.
    gsub(/command[[:space:]]+-v[[:space:]]+vicinae[[:space:]]+/, \
        "command -v vicinae.AppImage ", value)
    gsub(/command[[:space:]]+-v[[:space:]]+vicinae[.]AppImage[[:space:]]+/, \
        "command -v vicinae.AppImage ", value)
    gsub(/command[[:space:]]+-v[[:space:]]+vicinae>/, \
        "command -v vicinae.AppImage>", value)
    gsub(/command[[:space:]]+-v[[:space:]]+vicinae[.]AppImage>/, \
        "command -v vicinae.AppImage>", value)
    if (mode == "server") {
        gsub(/"vicinae"[[:space:]]+"server"/, \
            "\"vicinae.AppImage\" \"server\"", value)
        gsub(/"vicinae[.]AppImage"[[:space:]]+"server"/, \
            "\"vicinae.AppImage\" \"server\"", value)
        gsub(/\\"vicinae\\"[[:space:]]+\\"server\\"/, \
            "\\\"vicinae.AppImage\\\" \\\"server\\\"", value)
        gsub(/\\"vicinae[.]AppImage\\"[[:space:]]+\\"server\\"/, \
            "\\\"vicinae.AppImage\\\" \\\"server\\\"", value)
        gsub(/"vicinae[[:space:]]+server"/, \
            "\"vicinae.AppImage server\"", value)
        gsub(/"vicinae[.]AppImage[[:space:]]+server"/, \
            "\"vicinae.AppImage server\"", value)
        gsub(/\(vicinae[[:space:]]+server\)/, \
            "(vicinae.AppImage server)", value)
        gsub(/\(vicinae[.]AppImage[[:space:]]+server\)/, \
            "(vicinae.AppImage server)", value)
    } else {
        gsub(/"vicinae"[[:space:]]+"toggle"/, \
            "\"vicinae.AppImage\" \"toggle\"", value)
        gsub(/"vicinae[.]AppImage"[[:space:]]+"toggle"/, \
            "\"vicinae.AppImage\" \"toggle\"", value)
        gsub(/\\"vicinae\\"[[:space:]]+\\"toggle\\"/, \
            "\\\"vicinae.AppImage\\\" \\\"toggle\\\"", value)
        gsub(/\\"vicinae[.]AppImage\\"[[:space:]]+\\"toggle\\"/, \
            "\\\"vicinae.AppImage\\\" \\\"toggle\\\"", value)
        gsub(/"vicinae[[:space:]]+toggle"/, \
            "\"vicinae.AppImage toggle\"", value)
        gsub(/"vicinae[.]AppImage[[:space:]]+toggle"/, \
            "\"vicinae.AppImage toggle\"", value)
        gsub(/\(vicinae[[:space:]]+toggle\)/, \
            "(vicinae.AppImage toggle)", value)
        gsub(/\(vicinae[.]AppImage[[:space:]]+toggle\)/, \
            "(vicinae.AppImage toggle)", value)
    }
    return value
}

{
    split_comment($0)
    candidate = code
    sub(/^[[:space:]]*/, "", candidate)
    if (candidate ~ /^\/\// || candidate ~ /^#/) {
        print
        next
    }
    if (index($0, "/*") > 0 || in_block_comment) {
        if (!in_block_comment && index($0, "*/") == 0) in_block_comment = 1
        if (index($0, "*/") > 0) in_block_comment = 0
        print
        next
    }
    if (code !~ /(^|[{;][[:space:]]*)spawn(-sh)?(-at-startup)?[[:space:]]+/ ||
        !target_present(code)) {
        print
        next
    }
    print convert(code) comment
}
