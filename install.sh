download_binary() {
    echo ""
    step "Checking for the latest DaggerConnect release ..."

    RELEASE_JSON=$(curl -fsSL "$LATEST_RELEASE_API" 2>/dev/null)

    LATEST_VERSION=$(echo "$RELEASE_JSON" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    ZIP_URL=$(echo "$RELEASE_JSON" | grep '"browser_download_url":' | grep -Eo 'https://[^"]+\.zip' | head -1)

    if [ -z "$LATEST_VERSION" ] || [ -z "$ZIP_URL" ]; then
        warn "Could not reach GitHub or find a release asset."
        if [ -f "$BINARY" ]; then
            chmod +x "$BINARY"
            ok "Using existing local binary: ${BINARY}"
            return 0
        fi
        error "No local binary found and GitHub is unreachable. Cannot continue."
    fi

    info "Latest release : ${LATEST_VERSION}"
    info "Asset          : $(basename "$ZIP_URL")"

    CURRENT_VERSION=""
    if [ -f "$BINARY" ]; then
        chmod +x "$BINARY"
        CURRENT_VERSION=$("$BINARY" -v 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    fi

    if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        ok "Already on the latest version (${CURRENT_VERSION})."
        return 0
    fi

    if [ -n "$CURRENT_VERSION" ]; then
        step "Updating DaggerConnect: ${CURRENT_VERSION} -> ${LATEST_VERSION} ..."
    else
        step "Downloading DaggerConnect ${LATEST_VERSION} ..."
    fi

    mkdir -p "$(dirname "$BINARY")"
    TMP_DIR=$(mktemp -d)
    ZIP_PATH="${TMP_DIR}/dagger.zip"

    [ -f "$BINARY" ] && cp "$BINARY" "${BINARY}.backup"

    if curl -fL --progress-bar "$ZIP_URL" -o "$ZIP_PATH"; then
        if ! command -v unzip &>/dev/null; then
            info "Installing unzip..."
            if command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y -qq unzip
            elif command -v yum &>/dev/null; then
                yum install -y -q unzip
            elif command -v dnf &>/dev/null; then
                dnf install -y -q unzip
            fi
        fi

        unzip -oq "$ZIP_PATH" -d "$TMP_DIR"

        # zip فقط باید شامل یک فایل (باینری) باشه -- همون فایلی که خودتون آپلود کردید
        EXTRACTED=$(find "$TMP_DIR" -maxdepth 1 -type f ! -name "*.zip" | head -1)

        if [ -z "$EXTRACTED" ]; then
            warn "No binary found inside the downloaded zip."
            rm -rf "$TMP_DIR"
            [ -f "${BINARY}.backup" ] && mv -f "${BINARY}.backup" "$BINARY"
            return 1
        fi

        chmod +x "$EXTRACTED"
        if "$EXTRACTED" -v >/dev/null 2>&1; then
            mv -f "$EXTRACTED" "$BINARY"
            rm -f "${BINARY}.backup"
            rm -rf "$TMP_DIR"
            ok "DaggerConnect updated to ${LATEST_VERSION}."

            mapfile -t SERVICES < <(list_services)
            if [ ${#SERVICES[@]} -gt 0 ]; then
                echo ""
                warn "Running services are still using the old binary in memory until restarted."
                ask RESTART_CHOICE "Restart all DaggerConnect services now? (y/n)" "y"
                if [ "$RESTART_CHOICE" = "y" ] || [ "$RESTART_CHOICE" = "Y" ]; then
                    for svc in "${SERVICES[@]}"; do
                        systemctl restart "$svc" && ok "Restarted: ${svc}" || warn "Failed to restart: ${svc}"
                    done
                fi
            fi
        else
            warn "Downloaded binary failed to run -- keeping the previous version."
            rm -rf "$TMP_DIR"
            [ -f "${BINARY}.backup" ] && mv -f "${BINARY}.backup" "$BINARY"
        fi
    else
        rm -rf "$TMP_DIR"
        warn "Download failed."
        if [ -f "${BINARY}.backup" ]; then
            mv -f "${BINARY}.backup" "$BINARY"
            warn "Keeping existing binary."
        elif [ -f "$BINARY" ]; then
            ok "Using existing binary: ${BINARY}"
        else
            error "No binary available and download failed. Cannot continue."
        fi
    fi
}
