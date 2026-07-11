#!/bin/bash

# Directory to store process IDs and logs for background tunnels
TRACK_DIR="$HOME/.cf_tunnels"
mkdir -p "$TRACK_DIR"

# Colors for menu
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 1. Install cloudflared if it is missing
install_cloudflared() {
    if ! command -v cloudflared &> /dev/null; then
        echo -e "${YELLOW}cloudflared is not installed. Installing now...${NC}"
        # Downloads the latest linux 64-bit binary
        curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o /tmp/cloudflared
        chmod +x /tmp/cloudflared
        # Requires sudo to move to /usr/local/bin
        sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
        echo -e "${GREEN}cloudflared installed successfully!${NC}"
        sleep 1
    fi
}

# 2. Helper: Ask for port and validate it is a number between 1 and 65535
get_valid_port() {
    local port
    while true; do
        # We send the prompt to stderr (>&2) so it doesn't get captured by the variable assignment
        read -p "Enter the port you want to forward (e.g., 8080): " port >&2
        
        # Regex to check if it's a number, then verify the range
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            echo "$port" # Return the valid port
            return 0
        else
            echo -e "${RED}Invalid input. Please enter a valid port number between 1 and 65535.${NC}" >&2
        fi
    done
}

# 3. Helper: Check if a local service is running on the port
check_local_service() {
    local port=$1
    echo -e "${CYAN}Checking if a service is running on port $port...${NC}"
    
    # Use bash's built-in /dev/tcp to attempt a connection to the port
    if (echo > /dev/tcp/127.0.0.1/$port) >/dev/null 2>&1; then
        echo -e "${GREEN}Success: An active service was detected on port $port!${NC}"
        return 0
    else
        echo -e "${YELLOW}Warning: No active local service detected on port $port.${NC}"
        echo -e "${YELLOW}The Cloudflare link might show a '502 Bad Gateway' error until you start your app.${NC}"
        read -p "Do you want to create the tunnel anyway? (y/n): " proceed
        if [[ "$proceed" =~ ^[Yy]$ ]]; then
            return 0
        else
            echo -e "${RED}Aborted. Returning to menu.${NC}"
            return 1
        fi
    fi
}

# 4. Helper: Extract the trycloudflare URL from a log file
wait_for_url() {
    local log_file=$1
    echo -n "Requesting tunnel URL from Cloudflare..."
    for i in {1..15}; do
        # Grep the log file for the specific trycloudflare format
        URL=$(grep -Eo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log_file" | head -n 1)
        if [ -n "$URL" ]; then
            echo -e "\n${GREEN}Success! Your URL is:${NC} ${CYAN}$URL${NC}\n"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo -e "\n${RED}Timeout: Could not retrieve URL. Check logs at $log_file${NC}\n"
}

# 5. Helper: Clean up dead tunnels from the tracker directory
cleanup_dead_tunnels() {
    for pid_file in "$TRACK_DIR"/*.pid; do
        [ -f "$pid_file" ] || continue
        PID=$(cat "$pid_file")
        if ! ps -p "$PID" > /dev/null; then
            # Process is dead, remove the tracker files
            PORT=$(basename "$pid_file" .pid)
            rm -f "$TRACK_DIR/$PORT.pid" "$TRACK_DIR/$PORT.log"
        fi
    done
}

# Main Application Run
install_cloudflared

while true; do
    cleanup_dead_tunnels
    echo -e "\n${CYAN}========================================${NC}"
    echo -e "${GREEN}           SuperTCPTunnelMenu           ${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "1) Start trycloudflare (Foreground)"
    echo "2) Start trycloudflare (Background)"
    echo "3) Stop a Background Tunnel"
    echo "4) List Active Tunnels"
    echo "5) Exit"
    echo -e "${CYAN}========================================${NC}"
    read -p "Select an option [1-5]: " OPTION

    case $OPTION in
        1)
            PORT=$(get_valid_port)
            if ! check_local_service "$PORT"; then
                continue # Skip back to the main menu if they abort
            fi
            
            echo -e "${YELLOW}Starting tunnel on port $PORT. Press Ctrl+C to stop.${NC}"
            # Runs directly in the terminal
            cloudflared tunnel --url http://localhost:$PORT
            ;;
        2)
            PORT=$(get_valid_port)
            
            if [ -f "$TRACK_DIR/$PORT.pid" ]; then
                echo -e "${RED}A tunnel is already running on port $PORT!${NC}"
                continue
            fi
            
            if ! check_local_service "$PORT"; then
                continue # Skip back to the main menu if they abort
            fi
            
            LOG_FILE="$TRACK_DIR/$PORT.log"
            PID_FILE="$TRACK_DIR/$PORT.pid"
            
            # Start in background using nohup, redirecting output to the log file
            nohup cloudflared tunnel --url "http://localhost:$PORT" > "$LOG_FILE" 2>&1 &
            PID=$!
            echo $PID > "$PID_FILE"
            
            # Fetch and display the URL
            wait_for_url "$LOG_FILE"
            ;;
        3)
            # Stop a tunnel
            if [ -z "$(ls -A "$TRACK_DIR"/*.pid 2>/dev/null)" ]; then
                echo -e "${YELLOW}No background tunnels are currently running.${NC}"
                continue
            fi
            
            echo -e "\n${YELLOW}Active Tunnels:${NC}"
            for pid_file in "$TRACK_DIR"/*.pid; do
                PORT=$(basename "$pid_file" .pid)
                echo " - Port $PORT"
            done
            
            read -p "Enter the port to stop (or 'all' to stop everything): " STOP_PORT
            
            if [ "$STOP_PORT" == "all" ]; then
                for pid_file in "$TRACK_DIR"/*.pid; do
                    PID=$(cat "$pid_file")
                    kill -9 "$PID" 2>/dev/null
                    rm -f "$pid_file" "${pid_file%.pid}.log"
                done
                echo -e "${GREEN}All background tunnels stopped.${NC}"
            elif [ -f "$TRACK_DIR/$STOP_PORT.pid" ]; then
                PID=$(cat "$TRACK_DIR/$STOP_PORT.pid")
                kill -9 "$PID" 2>/dev/null
                rm -f "$TRACK_DIR/$STOP_PORT.pid" "$TRACK_DIR/$STOP_PORT.log"
                echo -e "${GREEN}Tunnel on port $STOP_PORT stopped.${NC}"
            else
                echo -e "${RED}No active tunnel found for port $STOP_PORT.${NC}"
            fi
            ;;
        4)
            # List Tunnels
            if [ -z "$(ls -A "$TRACK_DIR"/*.pid 2>/dev/null)" ]; then
                echo -e "${YELLOW}No background tunnels are currently running.${NC}"
            else
                echo -e "\n${GREEN}Active Background Tunnels:${NC}"
                for pid_file in "$TRACK_DIR"/*.pid; do
                    PORT=$(basename "$pid_file" .pid)
                    LOG_FILE="$TRACK_DIR/$PORT.log"
                    URL=$(grep -Eo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$LOG_FILE" | head -n 1)
                    echo -e " -> ${CYAN}Port $PORT${NC} : $URL"
                done
            fi
            ;;
        5)
            echo -e "${GREEN}Exiting SuperTCPTunnelMenu...${NC}"
            break
            ;;
        *)
            echo -e "${RED}Invalid option. Please enter a number between 1 and 5.${NC}"
            ;;
    esac
done
