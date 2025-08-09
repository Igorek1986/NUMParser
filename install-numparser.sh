#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$(id -u)" -eq 0 ]; then
    USER_HOME="/root"
    USER_NAME="root"
    IS_ROOT=true
else
    USER_HOME="$HOME"
    USER_NAME="$(id -un)"
    IS_ROOT=false
fi

PROJECT_DIR="$USER_HOME/NUMParser"
DEFAULT_PORT=38888
NEED_RELOAD=false
MIN_GO_VERSION="1.18"

function error_exit {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

function get_shell_config {
    if [ -n "$ZSH_VERSION" ]; then
        if [ -f "$USER_HOME/.zprofile" ]; then
            echo "$USER_HOME/.zprofile"
        else
            echo "$USER_HOME/.zshrc"
        fi
    else
        if [ -f "$USER_HOME/.profile" ]; then
            echo "$USER_HOME/.profile"
        else
            echo "$USER_HOME/.bashrc"
        fi
    fi
}

function reload_shell {
    echo -e "${YELLOW}\nChanges to PATH require a shell reload.${NC}"
    if confirm "Would you like to reload the shell now? (Y/n) " "y"; then
        echo -e "${GREEN}Reloading shell...${NC}"
        cd ~ || cd /tmp
        exec $SHELL -l
    else
        echo -e "${YELLOW}Please manually reload your shell or run:${NC}"
        echo -e "  source $(get_shell_config)"
    fi
}

function check_go_installed {
    if ! command -v go >/dev/null 2>&1; then
        return 1
    fi

    echo -e "${GREEN}Go is already installed${NC}"
    local go_version_output=$(go version)
    echo -e "  Version: $go_version_output"

    # Extract version number
    local go_version=$(echo "$go_version_output" | awk '{print $3}' | sed 's/go//')

    # Compare versions
    if [ "$(printf '%s\n' "$MIN_GO_VERSION" "$go_version" | sort -V | head -n1)" != "$MIN_GO_VERSION" ]; then
        echo -e "${RED}Installed Go version ($go_version) is older than required ($MIN_GO_VERSION)${NC}"
        return 2
    fi

    return 0
}

function remove_old_go {
    echo -e "${YELLOW}Removing old Go installation...${NC}"

    # Remove Go binary
    sudo rm -f $(which go) 2>/dev/null

    # Remove Go installation directory
    if [ -d "/usr/local/go" ]; then
        sudo rm -rf /usr/local/go
    fi

    # Remove from PATH in shell config
    local SHELL_CONFIG=$(get_shell_config)
    if grep -q "/usr/local/go/bin" "$SHELL_CONFIG"; then
        sed -i '/\/usr\/local\/go\/bin/d' "$SHELL_CONFIG"
        NEED_RELOAD=true
    fi

    # Remove from current PATH
    export PATH=$(echo $PATH | sed -e 's|:/usr/local/go/bin||')
}

function install_go {
    local install_needed=false

    # Check if Go is installed and meets version requirements
    check_go_installed
    case $? in
        0)  # Go is installed and version is OK
            return
            ;;
        1)  # Go is not installed
            install_needed=true
            ;;
        2)  # Go is installed but version is too old
            if confirm "Go version is too old. Remove and install new version? (Y/n) " "y"; then
                remove_old_go
                install_needed=true
            else
                error_exit "Go version must be at least $MIN_GO_VERSION"
            fi
            ;;
    esac

    if $install_needed; then
        echo -e "${YELLOW}Installing Go...${NC}"
        GO_VERSION="1.24.4"
        GO_ARCHIVE="go${GO_VERSION}.linux-amd64.tar.gz"
        TEMP_DIR=$(mktemp -d)

        # Download Go
        echo -e "${YELLOW}Downloading Go ${GO_VERSION}...${NC}"
        curl -L "https://go.dev/dl/${GO_ARCHIVE}" -o "$TEMP_DIR/$GO_ARCHIVE" || error_exit "Failed to download Go"

        # Install Go
        echo -e "${YELLOW}Installing Go to /usr/local...${NC}"
        sudo tar -C /usr/local -xzf "$TEMP_DIR/$GO_ARCHIVE" || error_exit "Failed to install Go"

        # Add Go to PATH
        local SHELL_CONFIG=$(get_shell_config)
        if ! grep -q "/usr/local/go/bin" "$SHELL_CONFIG"; then
            echo "export PATH=\$PATH:/usr/local/go/bin" >> "$SHELL_CONFIG"
            NEED_RELOAD=true
        fi

        # Cleanup
        rm -rf "$TEMP_DIR"

        # Source the configuration
        export PATH=$PATH:/usr/local/go/bin
        source "$SHELL_CONFIG" 2>/dev/null || true

        # Verify installation
        if ! check_go_installed; then
            error_exit "Go installation failed"
        fi
    fi
}

function setup_project {
    echo -e "${YELLOW}Setting up project...${NC}"
    create_project_dir
    clone_repository
    setup_config_file
    build_project
    update_movies_api_config
}

function create_project_dir {
    [ ! -d "$PROJECT_DIR" ] && mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR" || error_exit "Could not enter project directory"
}

function clone_repository {
    if [ ! -d ".git" ]; then
        echo -e "${YELLOW}Cloning repository...${NC}"
        git clone https://github.com/Igorek1986/NUMParser.git . || error_exit "Failed to clone repository"
    fi
}

function setup_config_file {
    # Create config.yml from example if it doesn't exist
    if [ ! -f "config.yml" ]; then
        echo -e "${YELLOW}Creating config.yml from template...${NC}"
        if [ -f "config.yml.example" ]; then
            cp config.yml.example config.yml
        else
            echo -e "${RED}Warning: config.yml.example not found, creating empty config.yml${NC}"
            touch config.yml
        fi
    fi

    # Setup TMDB token
    setup_tmdb_token
}

function setup_tmdb_token {
    echo -e "\n${GREEN}=== TMDB Token Configuration ==="
    echo -e "==============================${NC}"

    local current_token=$(grep -oP "tmdbtoken:\s*'\K[^']*" config.yml 2>/dev/null || echo "Bearer TOKEN")

    # Check token validity
    if [[ "$current_token" == "Bearer TOKEN" || ! "$current_token" =~ ^Bearer\ [^[:space:]]+$ ]]; then
        echo -e "${YELLOW}Current token: ${current_token}${NC}"
        echo -e "${RED}Warning: Invalid or default token detected${NC}"

        if confirm "Update token now? (y/N) " "n"; then
            prompt_tmdb_token
        else
            echo -e "${YELLOW}You must update the token later in:${NC}"
            echo -e "${PROJECT_DIR}/config.yml"
        fi
    else
        echo -e "${GREEN}Valid token already configured${NC}"
        if confirm "Update existing token? (y/N) " "n"; then
            prompt_tmdb_token
        fi
    fi
}

function confirm {
    local prompt="$1"
    local default="${2:-n}"
    read -p "$prompt" response
    case "${response:-$default}" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

function prompt_tmdb_token {
    while true; do
        echo -e "\n${YELLOW}Enter new TMDB Bearer Token (format: Bearer YourTokenWithoutSpaces):${NC}"
        echo -n "Leave empty and press Enter to keep the default token: "
        read -e tmdb_token

        if [[ -z "$tmdb_token" ]]; then
            echo -e "${YELLOW}No token entered. Default token will be used.${NC}"
            return 0
        fi

        if [[ "$tmdb_token" =~ ^Bearer\ [^[:space:]]+$ ]]; then
            if grep -q "tmdbtoken:" config.yml; then
                sed -i "s|tmdbtoken:.*|tmdbtoken: '${tmdb_token}'|" config.yml
            else
                echo "tmdbtoken: '${tmdb_token}'" >> config.yml
            fi
            echo -e "${GREEN}Token updated successfully!${NC}"
            return 0
        else
            echo -e "${RED}Invalid format! Must start with 'Bearer' and contain no extra spaces.${NC}"
        fi
    done
}

function build_project {
    echo -e "${YELLOW}Building project...${NC}"
    go build -o NUMParser_deb ./cmd || error_exit "Failed to build project"
}

function check_movies_api_installed {
    if systemctl list-unit-files | grep -q "movies-api.service"; then
        return 0
    else
        return 1
    fi
}

function install_movies_api {
    echo -e "${YELLOW}movies-api is not installed. Would you like to install it now?${NC}"
    if confirm "Install movies-api? (Y/n) " "y"; then
        echo -e "${YELLOW}Installing movies-api...${NC}"
        bash <(curl -fsSL https://raw.githubusercontent.com/Igorek1986/movies-api/main/scripts/install-movies-api.sh) || error_exit "Failed to install movies-api"
        update_movies_api_config
    fi
}

function update_movies_api_config {
    # Check if movies-api service exists
    if check_movies_api_installed; then
        echo -e "${YELLOW}Found movies-api service${NC}"

        # Get current releases dir from movies-api .env
        local movies_api_env="$USER_HOME/movies-api/.env"
        if [ -f "$movies_api_env" ]; then
            local current_releases
            current_releases=$(grep -oP "^RELEASES_DIR\s*=\s*['\"]?\K[^'\"]*" "$movies_api_env" 2>/dev/null)

            local project_name=$(basename "$PROJECT_DIR")
            local new_releases="${project_name}/public/releases/"

            if [[ "$current_releases" != "$new_releases" ]]; then
                echo -e "${YELLOW}Current releases directory in movies-api: ${current_releases}${NC}"
                if confirm "Update movies-api releases directory to ${new_releases}? (Y/n) " "y"; then
                    sed -i "s|^RELEASES_DIR=.*|RELEASES_DIR='${new_releases}'|" "$movies_api_env" \
                        && echo -e "${GREEN}Updated releases directory in movies-api${NC}" \
                        || error_exit "Failed to update RELEASES_DIR"

                    if systemctl is-active --quiet movies-api; then
                        echo -e "${YELLOW}Restarting movies-api service...${NC}"
                        sudo systemctl restart movies-api || error_exit "Failed to restart movies-api"
                    fi
                fi
            else
                echo -e "${GREEN}movies-api already uses the correct releases directory${NC}"
            fi
        fi
    else
        install_movies_api
    fi
}

function setup_systemd {
    # Ask for port number
    echo -e "\n${GREEN}=== Service Port Configuration ===${NC}"
    read -p "Enter port number [${DEFAULT_PORT}]: " SERVICE_PORT
    SERVICE_PORT=${SERVICE_PORT:-$DEFAULT_PORT}

    echo -e "${YELLOW}Configuring systemd service on port ${SERVICE_PORT}...${NC}"

    # Create service file
    SERVICE_FILE="/etc/systemd/system/numparser.service"
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=NUMParser Service
Wants=network.target
After=network.target

[Service]
User=$USER_NAME
Group=$USER_NAME
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/NUMParser_deb
Environment=GIN_MODE=release
Environment=PORT=$SERVICE_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable numparser
    sudo systemctl start numparser
}

# Main installation process
echo -e "${GREEN}Starting NUMParser installation...${NC}"

# Install dependencies
if $IS_ROOT; then
    apt-get update && apt-get install -y git curl wget || error_exit "Failed to install system dependencies"
else
    sudo apt-get update && sudo apt-get install -y git curl wget || error_exit "Failed to install system dependencies"
fi

install_go
setup_project
setup_systemd

# Final instructions
echo -e "\n${GREEN}=== Installation Completed Successfully! ===${NC}"
echo -e "Service is running as ${YELLOW}numparser${NC}"
echo -e "Access URL: ${YELLOW}http://$(hostname -I | awk '{print $1}'):${SERVICE_PORT}${NC}"
echo -e "\n${GREEN}Management commands:${NC}"
echo -e "Check status: ${YELLOW}sudo systemctl status numparser${NC}"
echo -e "Restart service: ${YELLOW}sudo systemctl restart numparser${NC}"
echo -e "View logs: ${YELLOW}sudo journalctl -u numparser -f${NC}"
echo -e "\n${GREEN}Important paths:${NC}"
echo -e "Project directory: ${YELLOW}${PROJECT_DIR}${NC}"
echo -e "Configuration file: ${YELLOW}${PROJECT_DIR}/config.yml${NC}"
echo -e "Releases directory: ${YELLOW}${PROJECT_DIR}/public/releases/${NC}"

# Offer to reload shell if needed
if $NEED_RELOAD; then
    reload_shell
fi