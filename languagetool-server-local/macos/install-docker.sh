#!/usr/bin/env bash
set -euo pipefail

# Cleanup handler
cleanup() {
    local exit_code=$?
    if [[ -n "${DMG_PATH:-}" ]] && [[ -f "$DMG_PATH" ]]; then
        echo "Cleaning up temporary files..."
        rm -f "$DMG_PATH"
    fi
    if mount | grep -q "/Volumes/Docker"; then
        hdiutil detach "/Volumes/Docker" -quiet 2>/dev/null || true
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM

# Color output (optional, degrades gracefully)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() { echo -e "${RED}Error: $1${NC}" >&2; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

echo "=== Docker Desktop Installer for macOS ==="
echo ""

# Check macOS version (Docker requires 10.15+)
MAC_VERSION=$(sw_vers -productVersion)
MAJOR_VERSION=$(echo "$MAC_VERSION" | cut -d. -f1)
MINOR_VERSION=$(echo "$MAC_VERSION" | cut -d. -f2)

if [[ "$MAJOR_VERSION" -lt 10 ]] || { [[ "$MAJOR_VERSION" -eq 10 ]] && [[ "$MINOR_VERSION" -lt 15 ]]; }; then
    error "Docker Desktop requires macOS 10.15 (Catalina) or later"
    error "Your version: $MAC_VERSION"
    exit 1
fi

# Function to check Docker CLI exists and is functional
check_docker_cli() {
    if command -v docker &> /dev/null; then
        if timeout 2 docker --version &> /dev/null; then
            return 0
        fi
    fi
    return 1
}

# Function to check Docker daemon
check_docker_daemon() {
    if timeout 5 docker info &> /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Function to wait for Docker daemon with progress
wait_for_docker() {
    local max_wait=60
    echo "Waiting for Docker daemon to start (up to ${max_wait}s)..."

    for i in $(seq 1 $max_wait); do
        if check_docker_daemon; then
            echo ""
            success "Docker daemon ready"
            return 0
        fi
        sleep 1
        echo -n "."
    done

    echo ""
    return 1
}

# Check if Docker already installed and working
if check_docker_cli; then
    success "Docker CLI found: $(docker --version)"

    if check_docker_daemon; then
        success "Docker daemon running"

        # Verify with actual command
        if docker ps &> /dev/null; then
            echo ""
            success "Docker fully operational"
            echo ""
            echo "Next step: ./start-languagetool.sh"
            exit 0
        fi
    else
        warn "Docker installed but daemon not running"
        echo ""
        echo "Action required:"
        echo "1. Open 'Docker Desktop' from Applications (Cmd+Space → Docker)"
        echo "2. Accept any prompts (EULA, privileged access)"
        echo "3. Wait for whale icon in menu bar to become steady"
        echo "4. Run: ./install-docker.sh"
        echo ""
        echo "Or wait here for Docker to start..."

        if wait_for_docker; then
            echo ""
            success "Docker fully operational"
            echo ""
            echo "Next step: ./start-languagetool.sh"
            exit 0
        else
            error "Docker daemon did not start within 60 seconds"
            echo "Please start Docker Desktop manually and run this script again"
            exit 1
        fi
    fi
fi

echo "Docker not found. Installing..."
echo ""

# Prefer Homebrew installation (most reliable)
BREW_SUCCESS=false
if command -v brew &> /dev/null; then
    success "Homebrew found - using for installation"
    echo ""
    echo "Installing Docker Desktop via Homebrew..."
    echo "This may take 5-10 minutes..."
    echo ""

    if brew install --cask docker 2>&1 | tee /tmp/brew_output.txt; then
        success "Docker Desktop installed"
        BREW_SUCCESS=true
        rm -f /tmp/brew_output.txt
    else
        # Check if Homebrew itself has version requirements
        if grep -q "does not run on macOS versions older than" /tmp/brew_output.txt 2>/dev/null; then
            warn "Homebrew requires newer macOS version than installed"
            echo ""
            echo "This is a Homebrew compatibility issue, not a Docker issue."
            echo "Switching to manual DMG download..."
            echo ""
        else
            error "Homebrew installation failed"
            echo ""
            echo "Try manual installation:"
            echo "1. Visit: https://www.docker.com/products/docker-desktop"
            echo "2. Download for macOS"
            echo "3. Install Docker.app to Applications"
            rm -f /tmp/brew_output.txt
            exit 1
        fi
        rm -f /tmp/brew_output.txt
    fi
fi

if [[ "$BREW_SUCCESS" == "true" ]]; then
    # After Homebrew successful install, Docker CLI available but needs app launch
    echo ""
    success "Installation complete"
    echo ""
    echo "REQUIRED: Launch Docker Desktop for first time"
    echo ""
    echo "Steps:"
    echo "1. Open 'Docker Desktop' from Applications"
    echo "   (Cmd+Space, type 'Docker', press Enter)"
    echo "2. Click 'Accept' on Service Agreement"
    echo "3. Enter password when prompted for privileged access"
    echo "4. Wait for whale icon in menu bar (may take 30-60s)"
    echo ""
    read -p "Press Enter after Docker Desktop is running..."

    if wait_for_docker; then
        echo ""
        success "Docker fully operational"
        echo ""
        echo "Next step: ./start-languagetool.sh"
        exit 0
    else
        error "Docker daemon did not start within 60 seconds"
        echo "Please start Docker Desktop manually and run this script again"
        exit 1
    fi
else
    # Manual installation (either Homebrew not available or failed with fallback)
    if command -v brew &> /dev/null; then
        warn "Homebrew available but installation failed - using manual DMG download"
    else
        warn "Homebrew not found - using manual installation"
        echo ""
        echo "Recommendation: Install Homebrew for easier package management"
        echo "Visit: https://brew.sh"
    fi
    echo ""

    # Detect architecture correctly
    ARCH=$(uname -m)
    case "$ARCH" in
        arm64)
            DOCKER_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
            ARCH_NAME="Apple Silicon (M1/M2/M3/M4)"
            ;;
        x86_64)
            DOCKER_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
            ARCH_NAME="Intel"
            ;;
        *)
            error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    success "Detected: $ARCH_NAME"
    echo ""

    # Use unique temp path to avoid conflicts
    DMG_PATH="/tmp/Docker-$$-$(date +%s).dmg"

    echo "Downloading Docker Desktop (~600MB)..."
    echo "This may take 5-15 minutes depending on connection..."
    echo ""

    # Download with resume capability and progress
    if ! curl -fL -C - --progress-bar "$DOCKER_URL" -o "$DMG_PATH"; then
        error "Download failed"
        echo ""
        echo "Possible causes:"
        echo "- Network connectivity issues"
        echo "- Docker Hub temporarily unavailable"
        echo ""
        echo "Try again or use Homebrew: brew install --cask docker"
        exit 1
    fi

    # Verify download integrity
    if [[ ! -f "$DMG_PATH" ]] || [[ ! -s "$DMG_PATH" ]]; then
        error "Downloaded file is empty or missing"
        exit 1
    fi

    FILE_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || echo "0")
    if [[ "$FILE_SIZE" -lt 100000000 ]]; then  # Less than 100MB indicates problem
        error "Downloaded file too small ($FILE_SIZE bytes) - likely incomplete"
        exit 1
    fi

    success "Download complete ($(numfmt --to=iec-i --suffix=B $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes"))"
    echo ""

    echo "Mounting disk image..."
    if ! hdiutil attach "$DMG_PATH" -nobrowse -quiet 2>/dev/null; then
        error "Failed to mount DMG - file may be corrupted"
        echo "Try downloading again"
        exit 1
    fi

    # Verify volume mounted correctly
    if [[ ! -d "/Volumes/Docker" ]]; then
        error "Docker volume not found after mounting"
        exit 1
    fi

    if [[ ! -d "/Volumes/Docker/Docker.app" ]]; then
        error "Docker.app not found in mounted volume"
        hdiutil detach "/Volumes/Docker" -quiet 2>/dev/null || true
        exit 1
    fi

    echo "Installing Docker.app to Applications..."
    if ! cp -R "/Volumes/Docker/Docker.app" /Applications/ 2>/dev/null; then
        error "Failed to copy Docker.app"
        echo ""
        echo "Possible causes:"
        echo "- Insufficient permissions (need admin rights)"
        echo "- Not enough disk space"
        echo "- Existing Docker.app is open"
        echo ""
        echo "Try: sudo cp -R /Volumes/Docker/Docker.app /Applications/"
        hdiutil detach "/Volumes/Docker" -quiet 2>/dev/null || true
        exit 1
    fi

    success "Docker.app installed"
    echo ""

    echo "Cleaning up..."
    hdiutil detach "/Volumes/Docker" -quiet 2>/dev/null || true
    rm -f "$DMG_PATH"

    success "Cleanup complete"
    echo ""

    echo "REQUIRED: Launch Docker Desktop for first time"
    echo ""
    echo "Steps:"
    echo "1. Open Applications folder (Cmd+Shift+A)"
    echo "2. Double-click 'Docker'"
    echo "3. Click 'Open' if macOS shows security warning"
    echo "4. Accept Service Agreement"
    echo "5. Enter password for privileged access"
    echo "6. Wait for whale icon in menu bar"
    echo ""
    read -p "Press Enter after Docker Desktop is running..."

    # Check if Docker CLI became available (symlinks created by Docker Desktop)
    echo ""
    echo "Verifying Docker CLI..."

    for i in {1..10}; do
        if check_docker_cli; then
            success "Docker CLI available"
            break
        fi
        sleep 2
        echo -n "."
    done
    echo ""

    if ! check_docker_cli; then
        error "Docker CLI not found"
        echo ""
        echo "Docker Desktop may need more time to initialize"
        echo "Wait 30 seconds, then run: ./install-docker.sh"
        exit 1
    fi

    if wait_for_docker; then
        echo ""
        success "Docker fully operational"
        echo ""
        echo "Next step: ./start-languagetool.sh"
        exit 0
    else
        error "Docker daemon not responding"
        echo "Restart Docker Desktop and try again"
        exit 1
    fi
fi
