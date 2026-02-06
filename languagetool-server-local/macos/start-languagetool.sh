#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="languagetool-server"
PORT="8081"
INTERNAL_PORT="8010"
SERVER_URL="http://localhost:$PORT"
IMAGE="erikvl87/languagetool:latest"
MAX_HEALTH_WAIT=45

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error() { echo -e "${RED}Error: $1${NC}" >&2; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
info() { echo -e "${BLUE}ℹ $1${NC}"; }

echo "=== LanguageTool Server Manager ==="
echo ""

# Check Docker installed
if ! command -v docker &> /dev/null; then
    error "Docker not found"
    echo ""
    echo "Run: ./install-docker.sh"
    exit 1
fi

# Check Docker daemon with timeout and helpful error
echo "Checking Docker daemon..."
if ! timeout 5 docker info &> /dev/null 2>&1; then
    error "Docker daemon not responding"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check Docker Desktop is running (whale icon in menu bar)"
    echo "2. If icon is blinking, wait for it to become steady"
    echo "3. Try: open -a Docker"
    echo "4. If problem persists, restart Docker Desktop"
    echo ""

    # Offer to wait
    read -p "Wait for Docker to start? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for i in {1..30}; do
            if timeout 5 docker info &> /dev/null 2>&1; then
                success "Docker daemon ready"
                break
            fi
            sleep 2
            echo -n "."
        done
        echo ""

        if ! timeout 5 docker info &> /dev/null 2>&1; then
            error "Docker still not responding"
            exit 1
        fi
    else
        exit 1
    fi
else
    success "Docker daemon running"
fi

echo ""

# Check port availability BEFORE any container operations
if command -v lsof &> /dev/null; then
    if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        error "Port $PORT already in use"
        echo ""

        PID=$(lsof -Pi :$PORT -sTCP:LISTEN -t | head -1)
        echo "Process details:"
        ps -p "$PID" -o pid=,comm=,args= 2>/dev/null || echo "PID: $PID (details unavailable)"
        echo ""

        # Check if it's our container
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
            CONTAINER_PORT=$(docker port "$CONTAINER_NAME" 2>/dev/null | grep "0.0.0.0:$PORT" || true)
            if [[ -n "$CONTAINER_PORT" ]]; then
                warn "Port occupied by our own container"
                info "Server already running at: $SERVER_URL"
                echo ""
                echo "Commands:"
                echo "  Stop:    docker stop $CONTAINER_NAME"
                echo "  Restart: docker restart $CONTAINER_NAME"
                echo "  Logs:    docker logs -f $CONTAINER_NAME"
                exit 0
            fi
        fi

        echo "Solutions:"
        echo "1. Stop the conflicting process: kill $PID"
        echo "2. Change port in this script (edit PORT variable)"
        echo "3. Find what's using port: lsof -Pi :$PORT"
        exit 1
    fi
fi

# Check if container exists and get state
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    CONTAINER_STATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    CONTAINER_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "none")

    info "Found existing container (state: $CONTAINER_STATE)"

    case "$CONTAINER_STATE" in
        running)
            # Verify actually healthy
            if [[ "$CONTAINER_HEALTH" == "healthy" ]] || curl -sf "$SERVER_URL/v2/languages" &>/dev/null; then
                success "Server already running and healthy"
                echo ""
                info "Server: $SERVER_URL"
                echo ""
                echo "Test command:"
                echo "  curl '$SERVER_URL/v2/languages' | jq ."
                exit 0
            else
                warn "Container running but not responding"
                echo "Restarting..."
                docker restart "$CONTAINER_NAME" &>/dev/null || {
                    error "Restart failed"
                    echo "Check logs: docker logs $CONTAINER_NAME"
                    exit 1
                }
            fi
            ;;
        exited)
            # Check exit code
            EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
            if [[ "$EXIT_CODE" != "0" ]] && [[ "$EXIT_CODE" != "unknown" ]]; then
                warn "Container exited with error code: $EXIT_CODE"
                echo ""
                echo "Recent logs:"
                docker logs --tail 20 "$CONTAINER_NAME" 2>&1 | head -10
                echo ""
                echo "Options:"
                echo "1. View full logs: docker logs $CONTAINER_NAME"
                echo "2. Remove and recreate: docker rm $CONTAINER_NAME && ./start-languagetool.sh"
                echo ""
                read -p "Remove and recreate container? (y/n) " -n 1 -r
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    docker rm -f "$CONTAINER_NAME" &>/dev/null
                    info "Container removed, recreating..."
                else
                    exit 1
                fi
            else
                info "Starting existing container..."
                if ! docker start "$CONTAINER_NAME" &>/dev/null; then
                    error "Failed to start container"
                    echo "Logs: docker logs $CONTAINER_NAME"
                    exit 1
                fi
            fi
            ;;
        paused)
            info "Unpausing container..."
            docker unpause "$CONTAINER_NAME" &>/dev/null
            ;;
        dead|removing)
            warn "Container in $CONTAINER_STATE state - removing..."
            docker rm -f "$CONTAINER_NAME" &>/dev/null || {
                error "Failed to remove dead container"
                echo "Try: docker rm -f $CONTAINER_NAME"
                exit 1
            }
            ;;
        *)
            warn "Container in unexpected state: $CONTAINER_STATE"
            echo "Removing and recreating..."
            docker rm -f "$CONTAINER_NAME" &>/dev/null || true
            ;;
    esac
fi

# Create new container if doesn't exist
if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "Pulling latest LanguageTool image..."
    echo "First run: ~300MB download, 2-5 minutes"
    echo ""

    # Pull with error handling
    if ! docker pull "$IMAGE"; then
        error "Failed to pull image"
        echo ""
        echo "Possible causes:"
        echo "- Network connectivity issues"
        echo "- Docker Hub rate limits (try again in 1 hour)"
        echo "- Docker Hub temporarily down"
        echo ""
        echo "Check status: https://status.docker.com"
        exit 1
    fi

    success "Image pulled successfully"
    echo ""

    echo "Creating container..."

    # Create with error capture
    if ! CREATE_OUTPUT=$(docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p "$PORT:$INTERNAL_PORT" \
        -e Java_Xms=512m \
        -e Java_Xmx=1g \
        --health-cmd="curl -f http://localhost:$INTERNAL_PORT/v2/languages || exit 1" \
        --health-interval=30s \
        --health-timeout=10s \
        --health-retries=3 \
        "$IMAGE" 2>&1); then
        error "Failed to create container"
        echo ""
        echo "Docker error:"
        echo "$CREATE_OUTPUT"
        echo ""

        # Check for common issues
        if echo "$CREATE_OUTPUT" | grep -q "port is already allocated"; then
            error "Port $PORT still in use (race condition)"
            echo "Wait a moment and try again"
        elif echo "$CREATE_OUTPUT" | grep -q "no space left"; then
            error "Insufficient disk space"
            echo "Free up space and try again"
        fi
        exit 1
    fi

    success "Container created"
fi

echo ""
echo "Waiting for server to start (up to ${MAX_HEALTH_WAIT}s)..."

# Health check with progress and early detection
CONTAINER_STARTED=false
for i in $(seq 1 $MAX_HEALTH_WAIT); do
    # Check if container still running
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        echo ""
        error "Container stopped unexpectedly"
        echo ""
        echo "Last 20 log lines:"
        docker logs --tail 20 "$CONTAINER_NAME" 2>&1
        echo ""
        echo "Full logs: docker logs $CONTAINER_NAME"
        exit 1
    fi

    # Try health check endpoint
    if curl -sf "$SERVER_URL/v2/languages" &>/dev/null; then
        CONTAINER_STARTED=true
        break
    fi

    # Show progress
    if (( i % 5 == 0 )); then
        echo -n " ${i}s"
    else
        echo -n "."
    fi

    sleep 1
done

echo ""

if [[ "$CONTAINER_STARTED" == "false" ]]; then
    error "Server did not respond within ${MAX_HEALTH_WAIT} seconds"
    echo ""
    echo "Container is still running but not accepting requests"
    echo ""
    echo "Possible causes:"
    echo "- Java initialization taking longer (low memory, slow CPU)"
    echo "- Configuration error"
    echo "- Port binding issue"
    echo ""
    echo "Diagnostics:"
    echo "  Logs:   docker logs -f $CONTAINER_NAME"
    echo "  Stats:  docker stats $CONTAINER_NAME"
    echo "  Inspect: docker inspect $CONTAINER_NAME"
    echo ""
    echo "The container will continue initializing in background"
    echo "Check back in 1-2 minutes or view logs"
    exit 1
fi

echo ""
success "Server ready!"
echo ""

# Verify with actual API call
if TEST_RESULT=$(curl -s -X POST "$SERVER_URL/v2/check" \
    -d 'language=en-US' \
    -d 'text=This is a teste.' 2>&1); then

    if echo "$TEST_RESULT" | grep -q '"matches"'; then
        success "API test passed (detected 'teste' typo)"
    else
        warn "Server responding but unexpected result"
        echo "Response: $TEST_RESULT"
    fi
else
    warn "Server up but API test failed"
fi

echo ""
info "Server URL: $SERVER_URL"
echo ""

echo "Quick test:"
echo "  curl '$SERVER_URL/v2/languages' | jq ."
echo ""
echo "Check text:"
echo "  curl -X POST '$SERVER_URL/v2/check' \\"
echo "    -d 'language=en-US' \\"
echo "    -d 'text=This is a teste.'"
echo ""

echo "Control commands:"
echo "  Stop:    docker stop $CONTAINER_NAME"
echo "  Start:   docker start $CONTAINER_NAME"
echo "  Restart: docker restart $CONTAINER_NAME"
echo "  Logs:    docker logs -f $CONTAINER_NAME"
echo "  Status:  docker ps -f name=$CONTAINER_NAME"
echo "  Remove:  docker rm -f $CONTAINER_NAME"
echo ""

echo "Update to latest version:"
echo "  docker stop $CONTAINER_NAME"
echo "  docker rm $CONTAINER_NAME"
echo "  docker pull $IMAGE"
echo "  ./start-languagetool.sh"
echo ""

info "Server will auto-start when Docker runs (unless manually stopped)"
