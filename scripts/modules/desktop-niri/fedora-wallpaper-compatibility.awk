#!/usr/bin/awk -f

function replace_literal(value, old, new,    at) {
    while ((at = index(value, old)) > 0) {
        value = substr(value, 1, at - 1) new substr(value, at + length(old))
    }
    return value
}

function replace_query_pipeline(value) {
    value = replace_literal(value, "swww query | sed -n 's/.*image: //p'", \
        "awww query | sed -n 's/^.*currently displaying: image:[[:space:]]*//p'")
    value = replace_literal(value, "swww query | head -n 1 | awk -F ': ' '{print $2}' | awk '{print $1}'", \
        "awww query | sed -n 's/^.*currently displaying: image:[[:space:]]*//p'")
    value = replace_literal(value, "grep -oP 'image: \\K.*'", \
        "sed -n 's/^.*currently displaying: image:[[:space:]]*//p'")
    value = replace_literal(value, "swww-daemon", "awww-daemon")
    value = replace_literal(value, "swww", "awww")
    value = replace_literal(value, "WP_SWWW", "WP_AWWW")
    value = replace_literal(value, "swww query 无返回", "awww query 无返回")
    # The daemon may still be configuring its Wayland outputs when QuickShell
    # performs its first query.  Fedora installs this quiet, bounded wrapper;
    # keep the rest of the source pipeline (sed/grep) unchanged.
    value = replace_literal(value, "awww query", "shorin-fedora-awww-query")
    return value
}

{
    line = $0
    # Only transform the known wallpaper consumers.  Unrelated text in the
    # dotfiles remains source-authentic and cannot accidentally become a
    # backend command.
    if (FILENAME ~ /quickshell\/lockscreen\/shell[.]qml$/ ||
        FILENAME ~ /\/lockscreen\/shell[.]qml$/ ||
        FILENAME ~ /scripts\/matugen-select-type[.]sh$/ ||
        FILENAME ~ /scripts\/niri_set_overview_blur_dark_bg[.]sh$/ ||
        FILENAME ~ /scripts\/niri_auto_blur_bg[.]sh$/ ||
        FILENAME ~ /matugen\/config[.]toml$/) {
        line = replace_query_pipeline(line)
    }
    if (FILENAME ~ /scripts\/niri_auto_blur_bg[.]sh$/) {
        line = replace_literal(line, "image:[[:space:]]*([^[:space:]]+)", \
            "currently[[:space:]]+displaying:[[:space:]]*image:[[:space:]]*(.*)")
    }
    if (FILENAME ~ /scripts\/niri_auto_blur_bg[.]sh$/ ||
        FILENAME ~ /scripts\/niri_set_overview_blur_dark_bg[.]sh$/ ||
        FILENAME ~ /quickshell\/lockscreen\/shell[.]qml$/ ||
        FILENAME ~ /\/lockscreen\/shell[.]qml$/) {
        line = replace_literal(line, "awww query", "shorin-fedora-awww-query")
    }
    print line
}
