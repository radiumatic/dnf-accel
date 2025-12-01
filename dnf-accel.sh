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
cleanup_transaction() {
    echo -e "\e[34m[Cleanup]\e[0m Verifying installed packages..."
    count=0
    
    for link in "$TRANS_DIR"/*.rpm; do
        [ -e "$link" ] || continue
        pool_file=$(readlink -f "$link")
        FILE_NEVRA=$(rpm -qp --queryformat '%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.%{ARCH}' "$pool_file" 2>/dev/null)
        FILE_NEVRA="${FILE_NEVRA//(none)/0}"

        if rpm -q "$FILE_NEVRA" &> /dev/null; then
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
    install|reinstall|upgrade|update|downgrade)
        
        # Force English output to ensure awk parsing works reliably
        export LC_ALL=C

        echo -e "\e[34m[Wrapper]\e[0m Calculating transaction..."
        
        DNF_CMD="$CMD"
        [ "$CMD" == "update" ] && DNF_CMD="upgrade"

        # Create a temp file to capture the transaction table
        TRANS_CAPTURE=$(mktemp)

        # 1. THE DRY RUN (Capture & Display)
        # We pipe to tee to show the user the output AND save it to file.
        # We capture PIPESTATUS[0] to get the exit code of DNF, not tee.
        "$REAL_DNF" "$DNF_CMD" "$@" --assumeno | tee "$TRANS_CAPTURE"
        EXIT_CODE=${PIPESTATUS[0]}

        # 0 = Success (assumeno)
        # 1 = Error
        if [ $EXIT_CODE -ne 0 ] && [ $EXIT_CODE -ne 1 ]; then
            rm -f "$TRANS_CAPTURE"
            exit $EXIT_CODE
        fi

        # 2. CONFIRMATION
        echo ""
        read -p "Proceed with aria2 download and install? [y/N]: " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted by user."
            rm -f "$TRANS_CAPTURE"
            exit 1
        fi

        # 3. RESOLVE URLS (Parsing Logic)
        echo -e "\e[32m[Wrapper]\e[0m Parsing transaction and resolving URLs..."
        > "$CACHE_ROOT/urls.txt"

        # Execute the user-defined AWK logic to extract NEVRA (Name-Version.Arch)
        # Note: $1=Name, $2=Arch, $3=Version. 
        # Result format: Name-Version.Arch (which includes Release in DNF output)
        PACKAGES_LIST=$(awk '$2 == "x86_64" || $2 == "aarch64" || $2 == "noarch" || $2 == "i686" { print $1 "-" $3 "." $2 }' "$TRANS_CAPTURE")

        # Clean up temp file
        rm -f "$TRANS_CAPTURE"

        if [ -z "$PACKAGES_LIST" ]; then
            echo -e "\e[33m[Wrapper]\e[0m No packages detected in transaction output."
            exit 0
        fi

        # Feed the list to dnf repoquery to get the actual download URLs
        # xargs -r ensures we don't run repoquery if the list is empty
        echo "$PACKAGES_LIST" | xargs -r "$REAL_DNF" repoquery --location > "$CACHE_ROOT/urls.txt" 2>/dev/null

        if [ ! -s "$CACHE_ROOT/urls.txt" ]; then
            echo -e "\e[31m[Error]\e[0m No URLs found via repoquery."
            exit 1
        fi

        # 4. DOWNLOAD (To Pool)
        echo -e "\e[32m[Wrapper]\e[0m Downloading to cache pool..."
        if ! aria2c -i "$CACHE_ROOT/urls.txt" -d "$POOL_DIR" -c --console-log-level=warn; then
            echo -e "\e[31m[Error]\e[0m Download failed."
            exit 1
        fi

        # 5. ISOLATE (Pool -> Transaction Stage)
        echo -e "\e[32m[Wrapper]\e[0m Staging packages..."
        sudo rm -rf "$TRANS_DIR"
        sudo mkdir -p "$TRANS_DIR"

        while read -r url; do
            filename=$(basename "$url")
            if [ -f "$POOL_DIR/$filename" ]; then
                sudo ln -sf "$POOL_DIR/$filename" "$TRANS_DIR/$filename"
            fi
        done < "$CACHE_ROOT/urls.txt"

        # 6. INSTALL
        echo -e "\e[32m[Wrapper]\e[0m Installing..."
        sudo "$REAL_DNF" install "$TRANS_DIR"/*.rpm
        INSTALL_EXIT_CODE=$?

        # 7. CLEANUP
        if [ $INSTALL_EXIT_CODE -eq 0 ]; then
            cleanup_transaction
        else
            echo -e "\e[33m[Warning]\e[0m DNF reported errors. Keeping downloaded files in pool."
        fi
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
