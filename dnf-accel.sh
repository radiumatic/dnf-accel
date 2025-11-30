#!/bin/bash

# --- Configuration ---
REAL_DNF="/usr/bin/dnf"
CACHE_ROOT="/var/cache/dnf-aria-custom"
POOL_DIR="$CACHE_ROOT/pool"
TRANS_DIR="$CACHE_ROOT/transaction"

# Ensure aria2c exists
if ! command -v aria2c &> /dev/null; then
    echo "Error: aria2c is not installed. Falling back to standard dnf."
    exec "$REAL_DNF" "$@"
fi

# Ensure directories exist
if [ ! -d "$POOL_DIR" ]; then
    sudo mkdir -p "$POOL_DIR"
    sudo chmod 777 "$POOL_DIR"
fi

# --- Helper: Cleanup ---
# Checks only the files involved in the current transaction
cleanup_transaction() {
    echo -e "\e[34m[Cleanup]\e[0m Verifying installed packages..."
    count=0
    
    # Loop through the symlinks in the transaction folder
    for link in "$TRANS_DIR"/*.rpm; do
        [ -e "$link" ] || continue
        
        # Resolve the symlink to find the actual file in the pool
        # readlink -f gives us the absolute path to the file in /pool/
        pool_file=$(readlink -f "$link")
        
        # Get NEVRA (Name-Version...) from the file to query the RPM DB
        FILE_NEVRA=$(rpm -qp --queryformat '%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.%{ARCH}' "$pool_file" 2>/dev/null)
        FILE_NEVRA="${FILE_NEVRA//(none)/0}"

        # Ask RPM database: "Is this EXACT version installed?"
        if rpm -q "$FILE_NEVRA" &> /dev/null; then
            # Yes, it is installed. Delete the source file from the pool.
            sudo rm -f "$pool_file"
            ((count++))
        fi
    done
    
    if [ "$count" -gt 0 ]; then
        echo -e "\e[34m[Cleanup]\e[0m Reclaimed space: Removed $count installed packages from pool."
    fi
}

# --- Main Logic ---

CMD="$1"
shift

case "$CMD" in
    install|reinstall|upgrade|update)
        
        # 1. THE DRY RUN (Visuals & Size)
        echo -e "\e[34m[Wrapper]\e[0m Calculating transaction..."
        
        DNF_CMD="$CMD"
        [ "$CMD" == "update" ] && DNF_CMD="upgrade"

        # Run with --assumeno to force DNF to print the table and size, then quit.
        "$REAL_DNF" "$DNF_CMD" "$@" --assumeno
        EXIT_CODE=$?

        # 0 = Success (but we used assumeno, so it didn't install)
        # 1 = Error
        if [ $EXIT_CODE -ne 0 ] && [ $EXIT_CODE -ne 1 ]; then
            exit $EXIT_CODE
        fi

        # 2. CONFIRMATION
        echo ""
        read -p "Proceed with aria2 download and install? [y/N]: " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted by user."
            exit 1
        fi

        # 3. RESOLVE URLS
        echo -e "\e[32m[Wrapper]\e[0m Resolving URLs..."
        > "$CACHE_ROOT/urls.txt"

        if [[ "$DNF_CMD" == "upgrade" ]] && [[ $# -eq 0 ]]; then
            "$REAL_DNF" repoquery --upgrades --location --latest-limit 1 > "$CACHE_ROOT/urls.txt" 2>/dev/null
        else
            "$REAL_DNF" download --url --resolve "$@" > "$CACHE_ROOT/urls.txt" 2>/dev/null
        fi

        if [ ! -s "$CACHE_ROOT/urls.txt" ]; then
            echo -e "\e[31m[Error]\e[0m No URLs found."
            exit 0
        fi

        # 4. DOWNLOAD (To Pool)
        echo -e "\e[32m[Wrapper]\e[0m Downloading to cache pool..."
        if ! aria2c -i "$CACHE_ROOT/urls.txt" -d "$POOL_DIR" -c --console-log-level=warn; then
            echo -e "\e[31m[Error]\e[0m Download failed."
            exit 1
        fi

        # 5. ISOLATE (Pool -> Transaction Stage)
        echo -e "\e[32m[Wrapper]\e[0m Staging packages..."
        
        # Reset transaction dir
        sudo rm -rf "$TRANS_DIR"
        sudo mkdir -p "$TRANS_DIR"

        COUNT=0
        while read -r url; do
            filename=$(basename "$url")
            if [ -f "$POOL_DIR/$filename" ]; then
                # Symlink: TRANS_DIR/file.rpm -> POOL_DIR/file.rpm
                sudo ln -sf "$POOL_DIR/$filename" "$TRANS_DIR/$filename"
                ((COUNT++))
            fi
        done < "$CACHE_ROOT/urls.txt"

        # 6. INSTALL
        echo -e "\e[32m[Wrapper]\e[0m Installing..."
        sudo "$REAL_DNF" install "$TRANS_DIR"/*.rpm
        INSTALL_EXIT_CODE=$?

        # 7. CLEANUP
        # Only clean if DNF reported success (0).
        if [ $INSTALL_EXIT_CODE -eq 0 ]; then
            cleanup_transaction
        else
            echo -e "\e[33m[Warning]\e[0m DNF reported errors. Keeping downloaded files in pool for retry."
        fi

        # Always wipe the symlinks/stage directory at the end
        sudo rm -rf "$TRANS_DIR"
        ;;

    clean)
        if [[ "$1" == "all" ]]; then
            echo -e "\e[34m[Cleanup]\e[0m Nuke custom cache..."
            sudo rm -rf "$CACHE_ROOT"
        fi
        exec "$REAL_DNF" clean "$@"
        ;;

    *)
        exec "$REAL_DNF" "$CMD" "$@"
        ;;
esac
