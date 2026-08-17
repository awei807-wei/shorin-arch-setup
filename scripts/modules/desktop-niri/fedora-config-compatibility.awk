# Migrate only real Niri spawn commands.  KDL comments, blank lines, and
# ordinary text may mention an old command without becoming executable.

BEGIN {
    count=split(optional, commands, " ")
}

function read_kdl_string(text, start,    i,j,ch,nextch,value) {
    i=start
    while (i<=length(text) && substr(text,i,1) ~ /[[:space:]]/) i++
    if (substr(text,i,1) != "\"") return 0
    value=""
    for (j=i+1; j<=length(text); j++) {
        ch=substr(text,j,1)
        if (ch == "\\") {
            if (j < length(text)) {
                nextch=substr(text,j+1,1)
                value=value nextch
                j++
            } else value=value ch
        } else if (ch == "\"") {
            parsed_value=value
            parsed_end=j+1
            return 1
        } else value=value ch
    }
    return 0
}

function contains_command(text, command,    offset,found,before,after) {
    offset=1
    while (offset <= length(text)) {
        found=index(substr(text,offset), command)
        if (!found) return 0
        found=offset+found-1
        before=(found > 1 ? substr(text,found-1,1) : "")
        after=(found+length(command) <= length(text) ?
            substr(text,found+length(command),1) : "")
        if ((before == "" || before !~ /[[:alnum:]_-]/) &&
            (after == "" || after !~ /[[:alnum:]_-]/)) return 1
        offset=found+length(command)
    }
    return 0
}

# Find a spawn token outside quoted strings and require KDL command context.
# This prevents prose such as `description "spawn ..."` from being rewritten.
function find_actual_spawn(text, wanted,    i,ch,before,after,prefix,in_string,escaped) {
    in_string=0
    escaped=0
    for (i=1; i<=length(text)-length(wanted)+1; i++) {
        ch=substr(text,i,1)
        if (in_string) {
            if (escaped) escaped=0
            else if (ch == "\\") escaped=1
            else if (ch == "\"") in_string=0
            continue
        }
        if (ch == "\"") {
            in_string=1
            continue
        }
        if (substr(text,i,length(wanted)) != wanted) continue
        before=(i > 1 ? substr(text,i-1,1) : "")
        after=(i+length(wanted) <= length(text) ?
            substr(text,i+length(wanted),1) : "")
        if ((before != "" && before ~ /[[:alnum:]_-]/) ||
            (after != "" && after ~ /[[:alnum:]_-]/)) continue
        prefix=substr(text,1,i-1)
        sub(/[[:space:]]*$/, "", prefix)
        if (prefix ~ /^[[:space:]]*$/ || prefix ~ /[{;]$/) {
            spawn_position=i
            return 1
        }
    }
    return 0
}

function has_legacy_command(text) {
    return text ~ /lockscreen-wait[.]sh/ ||
        text ~ /polkit-gnome-authentication-agent-1/ ||
        text ~ /\/usr\/lib[^[:space:]" ]*polkit-gnome/
}

function is_initializer_command(text) {
    return (initializer != "" && contains_command(text, initializer)) ||
        contains_command(text, "shorin-fedora-wallpaper-session")
}

function is_wallpaper_startup_command(text) {
    return contains_command(text, "swww-daemon") ||
        contains_command(text, "awww-daemon") ||
        contains_command(text, "waypaper") ||
        text ~ /niri_set_overview_blur_dark_bg[.]sh/ ||
        text ~ /niri_auto_blur_bg[.]sh/
}

function is_lockscreen_quickshell_command(text) {
    return contains_command(text, "quickshell") &&
        text ~ /(^|[[:space:]])(-p[[:space:]]+)?[^[:space:]"']*lockscreen([/][^[:space:]"']*)?/ \
        || text ~ /quickshell[^"']*-[[:space:]]*p[[:space:]]+[^"']*lockscreen/
}

function shell_quote(value,    result) {
    result=value
    gsub(/\\/, "\\\\", result)
    gsub(/"/, "\\\"", result)
    gsub(/\$/, "\\$", result)
    return "\"" result "\""
}

function kdl_escape(value,    result) {
    result=value
    gsub(/\\/, "\\\\", result)
    gsub(/"/, "\\\"", result)
    return result
}

function replace_fedora_compatibility(text,    result) {
    result=text
    gsub(/lockscreen-wait[.]sh/, "lockscreen.sh", result)
    gsub(/\/usr\/lib[^[:space:]" ]*polkit-gnome-authentication-agent-1/, polkit, result)
    gsub(/polkit-gnome-authentication-agent-1/, polkit, result)
    if (is_lockscreen_quickshell_command(result)) result="lockscreen.sh"
    return result
}

{
    line=$0

    # Preserve blank and comment lines byte-for-byte, including indentation.
    if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*(\/\/|#)/) {
        if (!validate) print line
        next
    }
    if (in_block_comment) {
        if (!validate) print line
        if (index(line,"*/")) in_block_comment=0
        next
    }
    if (line ~ /^[[:space:]]*\/\*/) {
        if (!validate) print line
        if (!index(line,"*/")) in_block_comment=1
        next
    }

    token=""
    for (i=1; i<=4; i++) {
        if (i==1) candidate="spawn-sh-at-startup"
        if (i==2) candidate="spawn-at-startup"
        if (i==3) candidate="spawn-sh"
        if (i==4) candidate="spawn"
        if (find_actual_spawn(line,candidate)) {
            token=candidate
            position=spawn_position
            break
        }
    }
    if (token == "") {
        if (!validate) print line
        next
    }

    rest=substr(line,position+length(token))
    if (index(token,"spawn-sh") == 1) {
        if (!read_kdl_string(rest,1)) {
            if (!validate) print line
            next
        }
        original=parsed_value
        consumed=parsed_end
        if (wallpaper_startup && index(token,"-at-startup") > 0 &&
            (is_initializer_command(original) ||
             is_wallpaper_startup_command(original))) {
            if (validate) {
                if (is_initializer_command(original)) initializer_seen++
                else wallpaper_invalid=1
                next
            }
            if (is_initializer_command(original)) {
                if (!initializer_seen) print line
                initializer_seen=1
            } else if (!initializer_seen) {
                match(line, /^[[:space:]]*/)
                print substr(line, 1, RLENGTH) \
                    "spawn-at-startup \"" (initializer == "" ? \
                    "~/.local/bin/shorin-fedora-wallpaper-session" : initializer) "\""
                initializer_seen=1
            }
            next
        }
        if (validate) {
            if (has_legacy_command(original)) invalid=1
            if (require_lockscreen && contains_command(original,"lockscreen.sh")) {
                lockscreen_seen=1
            }
            for (i=1; i<=count; i++) {
                command=commands[i]
                if (contains_command(original,command) &&
                    index(original,"command -v " command) == 0) invalid=1
            }
            next
        }
        updated=replace_fedora_compatibility(original)
        changed=(updated != original)
        for (i=1; i<=count; i++) {
            command=commands[i]
            if (contains_command(updated,command) &&
                index(updated,"command -v " command) == 0) {
                updated="command -v " command \
                    " >/dev/null 2>&1 && (" updated ")"
                changed=1
                break
            }
        }
        if (changed) {
            replacement=token " \"" kdl_escape(updated) "\""
            line=substr(line,1,position-1) replacement \
                substr(rest,consumed)
        }
        print line
        next
    }

    for (j in values) delete values[j]
    n=0
    consumed=1
    first_consumed=1
    while (read_kdl_string(rest,consumed)) {
        n++
        values[n]=parsed_value
        consumed=parsed_end
        if (n == 1) first_consumed=consumed
    }
    if (n == 0) {
        if (!validate) print line
        next
    }
    if (wallpaper_startup && index(token,"-at-startup") > 0 &&
        (is_initializer_command(values[1]) ||
         is_wallpaper_startup_command(values[1]))) {
        if (validate) {
            if (is_initializer_command(values[1])) initializer_seen++
            else wallpaper_invalid=1
            next
        }
        if (is_initializer_command(values[1])) {
            if (!initializer_seen) print line
            initializer_seen=1
        } else if (!initializer_seen) {
            match(line, /^[[:space:]]*/)
            print substr(line, 1, RLENGTH) \
                "spawn-at-startup \"" (initializer == "" ? \
                "~/.local/bin/shorin-fedora-wallpaper-session" : initializer) "\""
            initializer_seen=1
        }
        next
    }
    if (validate) {
        if (has_legacy_command(values[1])) invalid=1
        if (require_lockscreen && contains_command(values[1],"lockscreen.sh")) {
            lockscreen_seen=1
        }
        for (i=1; i<=count; i++) {
            command=commands[i]
            if (contains_command(values[1],command)) invalid=1
        }
        next
    }

    first_original=values[1]
    if (is_lockscreen_quickshell_command(first_original)) {
        replacement=token " \"lockscreen.sh\""
        line=substr(line,1,position-1) replacement substr(rest,consumed)
        print line
        next
    }
    first_updated=replace_fedora_compatibility(first_original)
    base=first_updated
    sub(/^.*\//,"",base)
    for (i=1; i<=count; i++) if (base == commands[i]) break
    if (i<=count) {
        invocation=shell_quote(first_updated)
        for (j=2; j<=n; j++) {
            invocation=invocation " " shell_quote(values[j])
        }
        guarded="command -v " base \
            " >/dev/null 2>&1 && (" invocation ")"
        if (index(token,"-at-startup") > 0) {
            replacement="spawn-sh-at-startup \"" \
                kdl_escape(guarded) "\""
        } else {
            replacement="spawn-sh \"" kdl_escape(guarded) "\""
        }
        line=substr(line,1,position-1) replacement \
            substr(rest,consumed)
    } else if (first_updated != first_original) {
        replacement=token " \"" kdl_escape(first_updated) "\""
        line=substr(line,1,position-1) replacement \
            substr(rest,first_consumed)
    }
    print line
}

END {
    if (validate && (invalid || wallpaper_invalid ||
        (require_lockscreen && !lockscreen_seen) ||
        (wallpaper_startup && initializer_seen != 1))) exit 1
    if (!validate && wallpaper_startup && !initializer_seen) {
        print "spawn-at-startup \"" (initializer == "" ? \
            "~/.local/bin/shorin-fedora-wallpaper-session" : initializer) "\""
    }
}
