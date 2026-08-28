#!/usr/bin/env bash
# dnf-accel: Delegating downloads to aria2
#
# Usage: dnf-accel <dnf5 args...>

set -euo pipefail
export LC_ALL=C

DNF5_BIN="${DNF5_BIN:-dnf5}"
ARIA2C_BIN="${ARIA2C_BIN:-aria2c}"

# dnf can run as root or a regular user. 
if [[ -z "${CACHE_BASE:-}" ]]; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        CACHE_BASE="/var/cache/libdnf5"
    else
        CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/libdnf5"
    fi
fi

log() {
    echo "[dnf-accel] $*" >&2
}

# We only handle commands that may download packages. 
should_intercept() {
    for arg in "$@"; do
        [[ "$arg" == -* ]] && continue

        case "$arg" in
            install|upgrade|update|reinstall|downgrade|distro-sync|swap|builddep|debuginfo-install|do)
                return 0
                ;;
            *)
                return 1
                ;;
        esac
    done
    return 1
}

if ! should_intercept "$@"; then
    exec "$DNF5_BIN" "$@"
fi

# Separating arguments: catch some, modify some, and pass others
# to dnf. We use --assumeno to get planned downloads.
ASSUME_YES=0
PROBE_ARGS=("--color=never" "--assumeno")
REPO_OPTS=()

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    arg="${args[i]}"
    case "$arg" in
        -y|--assumeyes)
            ASSUME_YES=1 #We handle this separately. Isn't passed to dnf.
            ;;
        -q|--quiet|--color=*|--color)
            # Skip quiet/color options for the dry run.
            if [[ "$arg" == "--color" && $((i + 1)) -lt ${#args[@]} && "${args[i+1]}" != -* ]]; then
                ((i++))
            fi
            ;;
        --enablerepo=*|--disablerepo=*|--repoid=*|--repo=*|--releasever=*|--setopt=*|--config=*|--installroot=*)
            REPO_OPTS+=("$arg")
            PROBE_ARGS+=("$arg")
            ;;
        --enablerepo|--disablerepo|--repoid|--repo|--releasever|--setopt|--config|-c|--installroot)
            REPO_OPTS+=("$arg")
            PROBE_ARGS+=("$arg")
            if (( i + 1 < ${#args[@]} )) && [[ "${args[i+1]}" != -* ]]; then
                REPO_OPTS+=("${args[i+1]}")
                PROBE_ARGS+=("${args[i+1]}")
                ((i++))
            fi
            ;;
        *)
            PROBE_ARGS+=("$arg")
            ;;
    esac
done

log "Probing transaction to evaluate downloads..."

# Probe `dnf5` once to learn the planned transaction. We capture
# uncolored output (hence `--color=never`) so the parser below can
# operate on predictable text. The output is used only to determine
# which packages will be downloaded; the actual transaction runs
# later.
PROBE_OUTPUT="$("$DNF5_BIN" "${PROBE_ARGS[@]}" 2>&1 || true)"

# Parse the transaction table for NVRAs, operations, and replaced packages
#
# NVRA = Name-Version-Release.Arch (e.g. pkg-1.2.3-4.x86_64). The awk
# script below looks for transaction sections
# (Installing/Upgrading/etc.), collects lines that describe package
# downloads, and emits tab-separated records:
#   nvra<TAB>action<TAB>repo<TAB>old_nvra<TAB>old_repo
declare -a NVRAS=()
declare -A PKG_ACTIONS=()
declare -A PKG_PROBE_REPOS=()
declare -A PKG_OLD_NVRAS=()
declare -A PKG_OLD_REPOS=()

while IFS=$'\t' read -r nvra action repo old_nvra old_repo; do
    [[ -z "$nvra" ]] && continue
    NVRAS+=("$nvra")
    PKG_ACTIONS["$nvra"]="$action"
    PKG_PROBE_REPOS["$nvra"]="$repo"
    PKG_OLD_NVRAS["$nvra"]="$old_nvra"
    PKG_OLD_REPOS["$nvra"]="$old_repo"
done < <(
    awk '
        function flush() {
            if (current_nvra != "") {
                printf "%s\t%s\t%s\t%s\t%s\n", current_nvra, current_action, current_repo, current_old_nvra, current_old_repo;
                current_nvra = "";
                current_action = "";
                current_repo = "";
                current_old_nvra = "";
                current_old_repo = "";
            }
        }
        # We tell awk we are interested in these, so mark them for download and go to next line.
        /^Installing:/                  { flush(); action = "Install";    download = 1; next; }
        /^Installing dependencies:/     { flush(); action = "Dependency"; download = 1; next; }
        /^Installing weak dependencies:/{ flush(); action = "Weak Dep";   download = 1; next; }
        /^Upgrading:/                   { flush(); action = "Upgrade";    download = 1; next; }
        /^Downgrading:/                 { flush(); action = "Downgrade";  download = 1; next; }
        /^Reinstalling:/                { flush(); action = "Reinstall";  download = 1; next; }
        # We are not interested in these, so do not mark and next line.
        /^Removing:/ || /^Removing dependent packages:/ || /^Removing unused dependencies:/ || /^Transaction Summary:/ || /^Obsoleting:/ || /^Downgraded:/ || /^Removed:/ || /^Replaced:/ {
            flush(); download = 0; next;
        }
        download {
            # For indicating a replacement ("replacing ...") 
            # we construct the old NVRA and record
            # the repo it came from.
            if (/^[[:space:]]+replacing[[:space:]]+/) {
                sub(/^[[:space:]]+replacing[[:space:]]+/, "");
                if ($2 ~ /^(x86_64|i686|i386|aarch64|ppc64le|s390x|noarch|src)$/) {
                    old_ver = $3;
                    sub(/^[0-9]+:/, "", old_ver);
                    current_old_nvra = $1 "-" old_ver "." $2;
                    current_old_repo = $4;
                } else {
                    current_old_nvra = $1;
                    current_old_repo = $2;
                }
                next;
            }

            # Normal download lines include at least 5 fields and an
            # architecture in $2. We construct the NVRA from fields and
            # associate it with the detected action and repo.
            if (NF >= 5 && $2 ~ /^(x86_64|i686|i386|aarch64|ppc64le|s390x|noarch|src)$/) {
                flush();
                pkg_ver = $3;
                sub(/^[0-9]+:/, "", pkg_ver);
                current_nvra = $1 "-" pkg_ver "." $2;
                current_action = action;
                current_repo = $4;
                current_old_nvra = "";
                current_old_repo = "";
            }
        }
        END {
            flush();
        }
    ' <<< "$PROBE_OUTPUT"
)

# If we couldn't find any packages to download, we just call dnf.
if [[ ${#NVRAS[@]} -eq 0 ]]; then
    log "No packages require downloading. Handing over to dnf5."
    exec "$DNF5_BIN" "$@"
fi

# The repoquery call below returns lines of the form:
#   NVRA<TAB>repoid<TAB>location
# We read those lines into `URL_LINES` and then parse them to build
# mappings from NVRA -> URL and NVRA -> repoid. Anything not http(s) is left to dnf.
declare -A PKG_URLS
declare -A PKG_REPOS

readarray -t URL_LINES < <(
    "$DNF5_BIN" repoquery --available "${REPO_OPTS[@]}" \
        --queryformat=$'%{name}-%{version}-%{release}.%{arch}\t%{repoid}\t%{location}\n' \
        "${NVRAS[@]}" 2>/dev/null
)

for line in "${URL_LINES[@]}"; do
    [[ -z "$line" ]] && continue
    IFS=$'\t' read -r nvra repoid location <<< "$line"
    if [[ "$location" == http* ]]; then
        PKG_URLS["$nvra"]="$location"
        PKG_REPOS["$nvra"]="$repoid"
    fi
done

# --- Layout & Dynamic Sizing Helpers ---

format_package_table() {
    local limit="${1:-${#NVRAS[@]}}"
    local term_cols
    term_cols=$(tput cols 2>/dev/null || echo 120)

    local max_pkg=7      # length of "PACKAGE"
    local max_op=9       # length of "OPERATION"
    local max_former=14  # length of "FORMER PACKAGE"

    local -a pkg_displays=()
    local -a op_displays=()
    local -a former_displays=()
    local -a op_colors=()

    for ((j = 0; j < limit && j < ${#NVRAS[@]}; j++)); do
        local nvra="${NVRAS[j]}"
        local repo="${PKG_REPOS["$nvra"]:-${PKG_PROBE_REPOS["$nvra"]:-unknown}}"
        local op="${PKG_ACTIONS["$nvra"]:-Install}"
        local old_nvra="${PKG_OLD_NVRAS["$nvra"]:-}"
        local old_repo="${PKG_OLD_REPOS["$nvra"]:-}"

        local pkg_disp="${nvra} (${repo})"
        local former_disp="-"
        if [[ -n "$old_nvra" ]]; then
            if [[ -n "$old_repo" ]]; then
                former_disp="${old_nvra} (${old_repo})"
            else
                former_disp="${old_nvra}"
            fi
        fi

        local op_color="\033[37m"
        case "$op" in
            Upgrade)    op_color="\033[1;36m" ;; # Cyan
            Install)    op_color="\033[1;32m" ;; # Green
            Dependency) op_color="\033[34m"   ;; # Blue
            "Weak Dep") op_color="\033[35m"   ;; # Magenta
            Downgrade)  op_color="\033[1;33m" ;; # Yellow
            Reinstall)  op_color="\033[36m"   ;; # Cyan
        esac

        pkg_displays+=("$pkg_disp")
        op_displays+=("$op")
        former_displays+=("$former_disp")
        op_colors+=("$op_color")

        (( ${#pkg_disp} > max_pkg )) && max_pkg=${#pkg_disp}
        (( ${#op} > max_op )) && max_op=${#op}
        (( ${#former_disp} > max_former )) && max_former=${#former_disp}
    done

    # Adjust widths proportionally if total width exceeds terminal width
    local total_needed=$((max_pkg + max_op + max_former + 4))
    if (( total_needed > term_cols )); then
        local available_for_pkgs=$((term_cols - max_op - 4))
        if (( available_for_pkgs > 20 )); then
            max_pkg=$((available_for_pkgs / 2))
            max_former=$((available_for_pkgs - max_pkg))
        fi
    fi

    # Build dynamic separator lines
    local sep_pkg sep_op sep_former
    printf -v sep_pkg '%*s' "$max_pkg" ''
    printf -v sep_op '%*s' "$max_op" ''
    printf -v sep_former '%*s' "$max_former" ''

    # Print Table Header
    printf "\033[1;37m%-*s  %-*s  %-*s\033[0m\n" "$max_pkg" "PACKAGE" "$max_op" "OPERATION" "$max_former" "FORMER PACKAGE"
    printf "\033[90m%s  %s  %s\033[0m\n" "${sep_pkg// /-}" "${sep_op// /-}" "${sep_former// /-}"

    # Print Table Rows
    for ((j = 0; j < ${#pkg_displays[@]}; j++)); do
        local p="${pkg_displays[j]}"
        local o="${op_displays[j]}"
        local f="${former_displays[j]}"
        local c="${op_colors[j]}"

        # Truncate if exceeding allocated column width
        if (( ${#p} > max_pkg )); then
            p="${p:0:$((max_pkg - 1))}…"
        fi
        if [[ "$f" != "-" ]] && (( ${#f} > max_former )); then
            f="${f:0:$((max_former - 1))}…"
        fi

        if [[ "$f" == "-" ]]; then
            printf "%-*s  ${c}%-*s\033[0m  \033[90m%-*s\033[0m\n" "$max_pkg" "$p" "$max_op" "$o" "$max_former" "-"
        else
            printf "%-*s  ${c}%-*s\033[0m  %-*s\n" "$max_pkg" "$p" "$max_op" "$o" "$max_former" "$f"
        fi
    done
}

extract_summary() {
    awk '
        /Transaction Summary:/ { show = 1 }
        /Is this ok|Operation aborted/ { show = 0 }
        show { print }
    ' <<< "$PROBE_OUTPUT"
}

# --- Interactive Layout & Prompt ---

if [[ "$ASSUME_YES" -eq 0 ]]; then
    TERM_LINES=$(tput lines 2>/dev/null || echo 24)
    TOTAL_PKGS=${#NVRAS[@]}
    MAX_DISPLAY_PKGS=$((TERM_LINES - 12))

    echo -e "\n\033[1;37mTransaction Overview:\033[0m"

    if (( TOTAL_PKGS > MAX_DISPLAY_PKGS && MAX_DISPLAY_PKGS > 5 )); then
        HEAD_COUNT=$((MAX_DISPLAY_PKGS - 3))
        format_package_table "$HEAD_COUNT"
        HIDDEN_COUNT=$((TOTAL_PKGS - HEAD_COUNT))
        printf "\033[33m... [%d more packages hidden — enter 'v' at prompt to view full list] ...\033[0m\n" "$HIDDEN_COUNT"
    else
        format_package_table
    fi

    echo
    extract_summary
    echo

    while true; do
        PROMPT_REPLY=""
        if [[ -t 0 ]]; then
            read -r -p "Is this ok [y/N/v (view all)]: " PROMPT_REPLY
        elif [[ -e /dev/tty ]]; then
            read -r -p "Is this ok [y/N/v (view all)]: " PROMPT_REPLY < /dev/tty
        else
            log "Error: Non-interactive terminal and no -y/--assumeyes flag provided."
            exit 1
        fi

        case "$PROMPT_REPLY" in
            [vV]*)
                PAGER_CMD="${PAGER:-less -R}"
                format_package_table | $PAGER_CMD
                echo
                extract_summary
                echo
                ;;
            [yY]|[yY][eE][sS])
                break
                ;;
            *)
                log "Operation aborted by user."
                exit 1
                ;;
        esac
    done
fi

log "Identified ${#NVRAS[@]} package(s) for download."

# Find the most recently modified cache directory for a repo
find_cache_dir() {
    local repo_id="$1"
    local -a dirs=()

    shopt -s nullglob
    # Cache directories are created with a repo-id plus a hash. We pick the most recently
    # modified of those directories as the active cache.
    dirs=("$CACHE_BASE"/"$repo_id"-????????????????)
    shopt -u nullglob

    [[ ${#dirs[@]} -eq 0 ]] && return 1

    local newest="${dirs[0]}"
    local d
    for d in "${dirs[@]}"; do
        [[ "$d" -nt "$newest" ]] && newest="$d"
    done

    echo "$newest"
}

# Build aria2c batch file
ARIA2_INPUT_FILE=$(mktemp /tmp/dnf-accel-XXXXXX.txt)
trap 'rm -f "$ARIA2_INPUT_FILE"' EXIT INT TERM

DL_COUNT=0
declare -A CACHE_DIRS

for nvra in "${NVRAS[@]}"; do
    url="${PKG_URLS["$nvra"]:-}"
    repo="${PKG_REPOS["$nvra"]:-${PKG_PROBE_REPOS["$nvra"]:-}}"
    [[ -z "$url" || -z "$repo" ]] && continue

    if [[ -z "${CACHE_DIRS["$repo"]:-}" ]]; then
        if cache_dir=$(find_cache_dir "$repo"); then
            CACHE_DIRS["$repo"]="$cache_dir/packages"
        else
            log "Warning: Cache directory for repo '$repo' not found; dnf5 will download it natively."
            continue
        fi
    fi

    dest_dir="${CACHE_DIRS["$repo"]}"
    filename="${url##*/}"
    if [[ ! -f "$dest_dir/$filename" || -f "$dest_dir/$filename.aria2" ]]; then
        mkdir -p "$dest_dir"
        cat <<EOF >> "$ARIA2_INPUT_FILE"
${url}
  dir=${dest_dir}
  out=${filename}
EOF
        DL_COUNT=$((DL_COUNT + 1))
    fi
done

# Configure aria2c parameters
DEFAULT_ARIA2_OPTS=(
    "--max-connection-per-server=4"
    "--split=4"
    "--min-split-size=1M"
    "--continue=true"
    "--allow-overwrite=false"
    "--console-log-level=warn"
    "--summary-interval=0"
)
ARIA2_ARGS=("${DEFAULT_ARIA2_OPTS[@]}")
if [[ -n "${ARIA2_EXTRA_OPTS:-}" ]]; then
    read -r -a EXTRA_OPTS <<< "$ARIA2_EXTRA_OPTS"
    ARIA2_ARGS+=("${EXTRA_OPTS[@]}")
fi

# Execute bulk download
if [[ "$DL_COUNT" -gt 0 ]]; then
    log "Downloading $DL_COUNT package(s) with aria2c..."
    "$ARIA2C_BIN" "${ARIA2_ARGS[@]}" -i "$ARIA2_INPUT_FILE"
    log "Download phase complete."
else
    log "All packages are already cached."
fi

# Run the actual dnf command
log "Executing transaction..."
if [[ "$ASSUME_YES" -eq 0 ]]; then
    exec "$DNF5_BIN" "$@" -y
else
    exec "$DNF5_BIN" "$@"
fi
