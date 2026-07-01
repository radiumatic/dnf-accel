#!/bin/bash
# dnf-axel: Wrapper that intercepts dnf5 package downloads and uses aria2c instead.
#
# Usage: dnf-axel <dnf5 args...>
# Install: symlink to /usr/local/bin/dnf5 or place earlier in PATH
#
# Supported commands: install, upgrade/update, reinstall, downgrade, distro-sync,
#                     swap, builddep, debuginfo-install, download, group install,
#                     group upgrade, replay, and --downloadonly variants.

set -euo pipefail

CACHE_BASE="/var/cache/libdnf5"
DNF5_BIN="${DNF5_BIN:-dnf5}"
ARIA2C_BIN="${ARIA2C_BIN:-aria2c}"

# --- Logging ---
log() { echo "[dnf-axel] $*" >&2; }

# --- Detect the command verb from the argument list ---
# Returns: VERB and remaining args in DNF_ARGS
parse_command() {
    DNF_ARGS=()
    VERB=""
    VERB_POS=-1

    local i=0
    local args=("$@")
    while [ $i -lt ${#args[@]} ]; do
        local arg="${args[$i]}"
        case "$arg" in
            -h|--help|--version|-C|--cacheonly|--debugsolver|--dump-main-config|--dump-repo-config|--dump-variables)
                # Commands that don't trigger downloads — pass through
                exec $DNF5_BIN "$@"
                ;;
            --config=*|-c)
                DNF_ARGS+=("$arg")
                [[ "$arg" != "-c" ]] || { i=$((i+1)); DNF_ARGS+=("${args[$i]}"); }
                ;;
            --setopt=*|--setvar=*|--releasever=*|--releasever-major=*|--releasever-minor=*|--installroot=*|--forcearch=*|--color=*|--comment=*|--enable-repo=*|--disable-repo=*|--repo=*|--enable-plugin=*|--disable-plugin=*|--exclude=*|--advisories=*|--advisory=*|--bzs=*|--bz=*|--cves=*|--cve=*|--from-repo=*|--from-vendor=*|--destdir=*|--urlprotocol=*)
                DNF_ARGS+=("$arg")
                ;;
            -x)
                DNF_ARGS+=("$arg")
                i=$((i+1))
                DNF_ARGS+=("${args[$i]}")
                ;;
            -*)
                # Other flags — collect but don't treat as verb
                DNF_ARGS+=("$arg")
                ;;
            group|environment|module)
                # Sub-commands: verb is "group", sub-verb goes into remaining args
                VERB="$arg"
                VERB_POS=$i
                # Don't consume the sub-verb — let it pass through to remaining args
                break
                ;;
            install|upgrade|update|reinstall|downgrade|distro-sync|swap|builddep|debuginfo-install|download|replay|remove|erase|autoremove|mark|search|list|info|provides|check-upgrade|check|leaves|repoclosure|repomanage|reposync|changelog|needs-restarting|do)
                VERB="$arg"
                VERB_POS=$i
                break
                ;;
            *)
                # Not a known verb, might be a package spec — pass through
                exec $DNF5_BIN "$@"
                ;;
        esac
        i=$((i+1))
    done

    # Collect remaining args after verb (these include package specs, flags, etc.)
    # Also prepend any global flags collected before the verb (like -y, -c, etc.)
    REMAINING_ARGS=("${DNF_ARGS[@]}" "${args[@]:$((VERB_POS+1))}")
}

# --- Parse --assumeno transaction table ---
# Input: raw dnf5 output on stdin
# Output: name<TAB>version<TAB>repo<TAB>action (only inbound actions)
parse_assumeno_output() {
    local action_context="install"
    local in_section=0

    while IFS= read -r line; do
        case "$line" in
            *"Upgrading:"*)          action_context="upgrade"; in_section=1; continue ;;
            *"Installing:"* | *"Installing dependencies:"* | *"Installing weak dependencies:"*)
                                      action_context="install"; in_section=1; continue ;;
            *"Reinstalling:"*)       action_context="reinstall"; in_section=1; continue ;;
            *"Downgrading:"*)        action_context="downgrade"; in_section=1; continue ;;
            *"Removing:"* | *"Removing unused dependencies:"*)
                                      action_context="remove"; in_section=1; continue ;;
            *"Replacing:"*)          continue ;;
            *"Transaction Summary:"* | *"Total size"* | *"After this operation"* | *"Nothing to do"* | *"Operation aborted"* | *"Need to download"*)
                                      in_section=0; continue ;;
        esac

        [[ "$in_section" -eq 0 ]] && continue
        [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ replacing ]] && continue

        echo "$line" | sed 's/^[[:space:]]*//' | awk -v action="$action_context" '
        {
            if (NF < 2) next
            # skip lines ending with period (e.g. "Nothing to do.")
            if ($NF ~ /\.$/) next
            # group info: continuation line starting with ":"
            if ($1 == ":") {
                pkg = ""
                for (i = 2; i <= NF; i++) { if (i > 2) pkg = pkg " "; pkg = pkg $i }
                if (pkg != "") printf "%s\t0:0\tunknown\t%s\n", pkg, action
                next
            }
            # group info: "Optional packages : abook" — find "packages :" pattern
            for (i = 1; i <= NF; i++) {
                if ($i == "packages" && (i+1) <= NF && $(i+1) == ":") {
                    pkg = ""
                    for (j = i+2; j <= NF; j++) { if (j > i+2) pkg = pkg " "; pkg = pkg $j }
                    if (pkg != "") printf "%s\t0:0\tunknown\t%s\n", pkg, action
                    break
                }
            }
            # transaction table format: ends with size unit
            size_unit = $NF
            if (size_unit !~ /^(B|KiB|MiB|GiB|TiB)$/) next
            if (NF < 6) next
            repo = $(NF-2)
            version = $(NF-3)
            arch = $(NF-4)
            name = ""
            for (i = 1; i <= NF-5; i++) {
                if (i > 1) name = name "-"
                name = name $i
            }
            if (arch !~ /^(x86_64|i686|i386|aarch64|ppc64le|s390x|noarch|src)$/) next
            if (version !~ /^[0-9]/) next
            printf "%s\t%s\t%s\t%s\n", name, version, repo, action
        }'
    done
}

# --- Get package list depending on command type ---
# Output: name<TAB>version<TAB>repo<TAB>action
get_package_list() {
    local verb="$1"
    shift
    local extra_args=("$@")

    case "$verb" in
        install|upgrade|update|reinstall|downgrade|distro-sync|swap|builddep|debuginfo-install)
            local dnf_verb="$verb"
            [ "$verb" = "update" ] && dnf_verb="upgrade"
            # Strip -y/--assumeyes from extra_args for --assumeno (it always prompts)
            local noauto_args=()
            for a in "${extra_args[@]}"; do
                [ "$a" = "-y" -o "$a" = "--assumeyes" ] && continue
                noauto_args+=("$a")
            done
            $DNF5_BIN "$dnf_verb" --assumeno "${noauto_args[@]}" 2>&1 | parse_assumeno_output
            ;;
        download)
            # For download, use --url --resolve to get URLs directly
            local urls=()
            while IFS= read -r line; do
                [[ "$line" =~ ^https?://.*\.rpm$ ]] && urls+=("$line")
            done < <($DNF5_BIN download --url --resolve --urlprotocol=https "${extra_args[@]}" 2>&1)

            if [ ${#urls[@]} -eq 0 ]; then
                return
            fi

            # Extract NEVRA from URLs, resolve repos
            for url in "${urls[@]}"; do
                local nevra
                nevra=$(basename "$url" .rpm)
                local repo evr
                repo=$($DNF5_BIN repoquery --latest-limit=1 --qf '%{repoid}' "$nevra" 2>/dev/null \
                    | grep -v '^[* ]' | grep -v '^Updating' | grep -v '^Repositories' | head -1)
                evr=$($DNF5_BIN repoquery --latest-limit=1 --qf '%{evr}' "$nevra" 2>/dev/null \
                    | grep -v '^[* ]' | grep -v '^Updating' | grep -v '^Repositories' | head -1)
                echo -e "${nevra}\t${evr:-?}\t${repo:-unknown}\tdownload"
            done
            ;;
        group)
            # extra_args = [flags..., "install"|"upgrade", group_name, ...]
            local group_subcmd=""
            local group_flags=()
            local group_name_args=()
            local found_subcmd=0
            for a in "${extra_args[@]}"; do
                if [ "$found_subcmd" -eq 0 ] && [[ "$a" == -* ]]; then
                    group_flags+=("$a")
                elif [ "$found_subcmd" -eq 0 ]; then
                    group_subcmd="$a"
                    found_subcmd=1
                else
                    group_name_args+=("$a")
                fi
            done
            case "$group_subcmd" in
                install|upgrade)
                    get_group_package_list "${group_name_args[@]}" "${group_flags[@]}"
                    ;;
                *)
                    log "Unsupported group action: $group_subcmd"
                    exec $DNF5_BIN "$VERB" "${extra_args[@]}"
                    ;;
            esac
            ;;
        replay)
            get_replay_package_list "${extra_args[0]}"
            ;;
        *)
            # Unknown verb — pass through
            read -ra _verb_words <<< "$verb"
            exec $DNF5_BIN "${_verb_words[@]}" "${extra_args[@]}"
            ;;
    esac
}

# --- Get group package list ---
get_group_package_list() {
    local group_id=""
    local with_optional=""
    for arg in "$@"; do
        case "$arg" in
            --with-optional) with_optional="with_optional" ;;
            -*) ;; # skip flags
            *) group_id="$arg" ;;
        esac
    done

    local group_info
    group_info=$($DNF5_BIN group info "$group_id" 2>/dev/null)

    local pkgs=()
    local in_packages=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '(Default|Mandatory|Optional|Conditional) packages'; then
            in_packages=1
            local pkg
            pkg=$(echo "$line" | awk -F: '{print $2}' | xargs)
            [ -n "$pkg" ] && pkgs+=("$pkg")
            continue
        fi
        if echo "$line" | grep -qE '^((Id|Name|Description|Installed|Order|Langonly|Uservisible|Repositories)[[:space:]]*:)'; then
            in_packages=0
            continue
        fi
        if [ "$in_packages" -eq 1 ]; then
            local pkg
            pkg=$(echo "$line" | awk -F: '{print $2}' | xargs)
            [ -n "$pkg" ] && pkgs+=("$pkg")
        fi
    done <<< "$group_info"

    if [ ${#pkgs[@]} -eq 0 ]; then
        log "Warning: no packages found in group '$group_id'"
        return
    fi

    # Resolve repos for all packages
    for pkg in "${pkgs[@]}"; do
        local repo
        repo=$($DNF5_BIN repoquery --latest-limit=1 --qf '%{repoid}' "$pkg" 2>/dev/null \
            | grep -v '^[* ]' | grep -v '^Updating' | grep -v '^Repositories' | head -1)
        local evr
        evr=$($DNF5_BIN repoquery --latest-limit=1 --qf '%{evr}' "$pkg" 2>/dev/null \
            | grep -v '^[* ]' | grep -v '^Updating' | grep -v '^Repositories' | head -1)
        echo -e "${pkg}\t${evr:-?}\t${repo:-unknown}\tinstall"
    done
}

# --- Get replay package list ---
get_replay_package_list() {
    local tx_path="$1"
    local packages_dir="$tx_path/packages"

    if [ ! -d "$packages_dir" ]; then
        log "Error: no packages directory in '$tx_path'"
        exit 1
    fi

    for rpm in "$packages_dir"/*.rpm; do
        [ -f "$rpm" ] || continue
        local nevra
        nevra=$(basename "$rpm" .rpm)
        local repo
        repo=$($DNF5_BIN repoquery --latest-limit=1 --qf '%{repoid}' "$nevra" 2>/dev/null \
            | grep -v '^[* ]' | grep -v '^Updating' | grep -v '^Repositories' | head -1)
        echo -e "${nevra}\t${repo:-unknown}\treplay"
    done
}

# --- Get URL for a package (NEVRA or name) ---
get_package_url() {
    local pkg="$1"
    $DNF5_BIN repoquery --latest-limit=1 --location "$pkg" 2>/dev/null \
        | grep -v '^[* ]' | grep -v '^Updating' | grep -v '^Repositories' | tail -1
}

# --- Find cache dir for a given repo ID ---
# Scans /var/cache/libdnf5/ for directories matching <repo_id>-<hash>
declare -A REPO_CACHE_MAP
find_cache_dir() {
    local repo_id="$1"

    if [ -n "${REPO_CACHE_MAP[$repo_id]+x}" ]; then
        echo "${REPO_CACHE_MAP[$repo_id]}"
        return
    fi

    for dir in "$CACHE_BASE"/*/; do
        [ -d "$dir" ] || continue
        local dir_name
        dir_name=$(basename "$dir")
        # Skip non-cache dirs (temporary_files.toml, etc.)
        [[ "$dir_name" =~ ^@ ]] && continue
        # Strip last 17 chars (dash + 16 hex hash) to get repo_id
        local dir_repo_id="${dir_name%?????????????????}"
        if [ "$dir_repo_id" = "$repo_id" ]; then
            REPO_CACHE_MAP["$repo_id"]="${dir%/}"
            echo "${dir%/}"
            return
        fi
    done
    echo ""
}

# --- Download packages via aria2c to cache dirs ---
download_with_aria2() {
    local -n pkg_list=$1

    if [ ${#pkg_list[@]} -eq 0 ]; then
        log "No packages to download."
        return
    fi

    # Build download list: URL -> cache_dir/packages/filename
    local aria2_input=""
    local count=0

    for entry in "${pkg_list[@]}"; do
        local nevra version repo action
        IFS=$'\t' read -r nevra version repo action <<< "$entry"

        # Skip remove actions — nothing to download
        [ "$action" = "remove" ] && continue

        local url
        url=$(get_package_url "$nevra")
        if [ -z "$url" ]; then
            log "Warning: could not resolve URL for $nevra, skipping"
            continue
        fi

        local filename
        filename=$(basename "$url")
        local cache_dir
        cache_dir=$(find_cache_dir "$repo")
        if [ -z "$cache_dir" ]; then
            log "Warning: could not find cache dir for repo '$repo', skipping $nevra"
            continue
        fi

        local dest="$cache_dir/packages/$filename"

        # Skip if already cached
        if [ -f "$dest" ]; then
            log "Already cached: $filename"
            continue
        fi

        mkdir -p "$cache_dir/packages"
        aria2_input+="$url"
        aria2_input+=$'\n'
        aria2_input+="  dir=$cache_dir/packages"
        aria2_input+=$'\n'
        aria2_input+="  out=$filename"
        aria2_input+=$'\n'
        count=$((count + 1))
    done

    if [ $count -eq 0 ]; then
        log "All packages already cached."
        return
    fi

    log "Downloading $count package(s) via aria2c..."
    echo "$aria2_input" | $ARIA2C_BIN \
        --max-connection-per-server=4 \
        --split=4 \
        --min-split-size=1M \
        --continue=true \
        --allow-overwrite=false \
        --console-log-level=warn \
        --summary-interval=0 \
        -i -

    log "Download complete."
}

# --- Main ---
parse_command "$@"

# If no verb detected, pass through
if [ -z "$VERB" ]; then
    exec $DNF5_BIN "$@"
fi

# Pass-through for commands that don't download packages
case "$VERB" in
    remove|erase|autoremove|mark|search|list|info|provides|check-upgrade|check|leaves|repoclosure|repomanage|reposync|changelog|needs-restarting|do)
        exec $DNF5_BIN "$@"
        ;;
esac

# Handle --downloadonly: strip it and add to DNF_ARGS, we handle download ourselves
DOWNLOAD_ONLY=0
HAS_YES=0
FINAL_ARGS=()
for arg in "${REMAINING_ARGS[@]}"; do
    if [ "$arg" = "--downloadonly" ]; then
        DOWNLOAD_ONLY=1
    elif [ "$arg" = "-y" -o "$arg" = "--assumeyes" ]; then
        HAS_YES=1
    else
        FINAL_ARGS+=("$arg")
    fi
done

log "Intercepting: dnf5 $VERB ${FINAL_ARGS[*]}"

# Step 1: Get list of packages that would be downloaded
PKG_LINES=()
while IFS= read -r line; do
    [ -n "$line" ] && PKG_LINES+=("$line")
done < <(get_package_list "$VERB" "${FINAL_ARGS[@]}")

if [ ${#PKG_LINES[@]} -eq 0 ]; then
    log "No packages to download, running dnf5 directly."
    exec $DNF5_BIN "$@"
fi

log "Packages to download:"
for line in "${PKG_LINES[@]}"; do
    log "  $line"
done

# Step 2: Download via aria2c
download_with_aria2 PKG_LINES

# Step 3: Run the original dnf5 command
# If --downloadonly was used, we already put packages in cache.
# dnf5 will find them and say "Already downloaded".
log "Running: dnf5 $VERB ${FINAL_ARGS[*]}"
read -ra VERB_WORDS <<< "$VERB"
if [ "$HAS_YES" -eq 1 ]; then
    exec $DNF5_BIN "${VERB_WORDS[@]}" -y "${FINAL_ARGS[@]}"
else
    exec $DNF5_BIN "${VERB_WORDS[@]}" "${FINAL_ARGS[@]}"
fi
