#!/bin/bash
set -euo pipefail

IMAGE_NAME="nelsonnunes/girmos-etc-app:latest"

# Check if Docker is installed
ensure_docker_installed() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is not installed."

    case "$(uname)" in
      Darwin)
        echo "On macOS, install Docker Desktop from:"
        echo "   https://docs.docker.com/desktop/setup/install/mac-install/"
        ;;
      Linux)
        echo "On Linux, install Docker Desktop from:"
        echo "   https://docs.docker.com/desktop/setup/install/linux/"
        ;;
      MINGW*|MSYS*|CYGWIN*)
        echo "On Windows, install Docker Desktop from:"
        echo "   https://docs.docker.com/desktop/setup/install/windows-install/"
        ;;
      *)
        echo "Please install Docker from https://docs.docker.com/get-started/get-docker/"
        ;;
    esac

    exit 1
  fi
}

# Ensure the Docker daemon is running (start Docker Desktop if needed)
ensure_docker_running() {
  # Already running?
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  case "$(uname)" in
    Darwin)
      echo "Starting Docker Desktop on macOS..."
      # Try to start Docker Desktop; -g = do not bring to front if already running
      open -ga Docker || open -a Docker || true
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "Starting Docker Desktop on Windows..."
      if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "Start-Process 'Docker Desktop' -WindowStyle Hidden" || true
      elif command -v cmd.exe >/dev/null 2>&1; then
        cmd.exe /c start "" "Docker Desktop" || true
      fi
      ;;
    Linux)
      echo "Docker daemon is not running."
      if command -v systemctl >/dev/null 2>&1; then
        # Attempt to start without prompting for password
        sudo -n systemctl start docker >/dev/null 2>&1 || \
          echo "Cannot auto-start docker (needs privileges). Try: sudo systemctl start docker"
      else
        echo "Please start the Docker daemon (dockerd) and re-run this script."
      fi
      ;;
  esac

  echo "Waiting for Docker daemon..."
  for i in {1..60}; do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "Docker daemon did not become ready. Please start Docker Desktop and rerun."
  exit 1
}

# Determine if a port is in use
is_port_in_use() {
  local port="$1"

  # 1) Try lsof (macOS/Linux/Git Bash often has it)
  if command -v lsof >/dev/null 2>&1; then
    # lsof exits 0 if a listener exists
    lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1
    return $?
  fi

  # 2) Try ss (common on modern Linux)
  if command -v ss >/dev/null 2>&1; then
    # ss exits 0 if it printed matches (we grep to force 0/1)
    ss -ltn "sport = :$port" 2>/dev/null | grep -q .
    return $?
  fi

  # 3) Fallback: Windows netstat (Git Bash/MSYS/Cygwin)
  case "$(uname)" in
    MINGW*|MSYS*|CYGWIN*)
      if command -v netstat >/dev/null 2>&1; then
        # Normalize CRLF and look for LISTEN on :port at end of local address
        netstat -an -p tcp 2>/dev/null \
          | tr -d '\r' \
          | awk -v p=":$port" '
              BEGIN{IGNORECASE=1}
              $1 ~ /^TCP$/ && $4 ~ p"$" && $6 ~ /LISTENING|LISTEN/ {found=1}
              END{exit !found}
            '
        return $?
      fi
      ;;
  esac

  # If we get here, we couldn't check; assume "not in use" to avoid blocking
  # You can 'return 0' to be conservative instead.
  return 1
}

# Pick a free port in the given range (default: 8888-8999)
pick_port() {
  local start="${1:-8888}"
  local end="${2:-8999}"
  local p="$start"
  while [ "$p" -le "$end" ]; do
    if ! is_port_in_use "$p"; then
      echo "$p"
      return 0
    fi
    p=$((p+1))
  done
  echo "No free port found in ${start}-${end}" >&2
  return 1
}

# Open url in browser
open_in_browser() {
  local url="$1"

  # Best for WSL: opens in the default Windows browser
  if command -v wslview >/dev/null 2>&1; then
    # install with: sudo apt update && sudo apt install -y wslu
    wslview "$url" >/dev/null 2>&1 && return 0
  fi

  # Windows-native fallbacks (work when called from WSL/Git Bash)
  if command -v powershell.exe >/dev/null 2>&1; then
    # Use Start-Process with single-quoted URL to avoid '&' issues
    powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 && return 0
  fi
  if command -v cmd.exe >/dev/null 2>&1; then
    cmd.exe /c start "" "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v explorer.exe >/dev/null 2>&1; then
    explorer.exe "$url" >/dev/null 2>&1 && return 0
  fi

  # POSIX fallbacks (mac/Linux with a GUI)
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 && return 0
  fi

  echo "Open this URL in your browser: $url"
  return 0
}

# Check if Docker is installed
ensure_docker_installed

# Ensure the Docker daemon is running
ensure_docker_running

# Check for running containers
running_id=$(docker ps --filter "ancestor=$IMAGE_NAME" --format '{{.ID}}' || true)

# Handle stop command
if [[ "${1:-}" == "stop" ]]; then
  if [[ -n "$running_id" ]]; then
    echo "Stopping containers for $IMAGE_NAME..."
    docker kill $running_id >/dev/null || true
    echo "Stopped: $running_id"
  else
    echo "No running containers for $IMAGE_NAME."
  fi
  exit 0
fi

# Optional: skip_update command to skip pulling the latest image
SKIP_UPDATE=false
if [[ "${1:-}" == "skip_update" ]]; then
  SKIP_UPDATE=true
fi

# Pull latest version
before_id="$(docker image inspect -f '{{.Id}}' "$IMAGE_NAME" 2>/dev/null || true)"
image_updated=false
if ! $SKIP_UPDATE; then
  echo "Pulling latest image: $IMAGE_NAME"
  if docker pull "$IMAGE_NAME" >/dev/null; then
    after_id="$(docker image inspect -f '{{.Id}}' "$IMAGE_NAME" 2>/dev/null || true)"
    if [[ -n "$before_id" && -n "$after_id" && "$before_id" != "$after_id" ]]; then
      image_updated=true
    fi
  else
    echo "Warning: 'docker pull' failed; continuing with the locally cached image (if any)."
    after_id="$before_id"
  fi
else
  echo "Skipped updating $IMAGE_NAME."
  after_id="$before_id"
fi

# If image updated, kill any running containers of this image
if $image_updated; then
  if [[ -n "${running_id}" ]]; then
    docker kill $running_id >/dev/null || true
  fi
  running_id=""
fi

# Common docker run options
HOST_PORT=$(pick_port 8888 8999)
COMMON_OPTS=(
  -p 127.0.0.1:${HOST_PORT}:8888
  --memory=4g
  --cpus=2
  --mount "type=bind,src=$(pwd),dst=/app/work"
)

# Run docker
if [[ "${1:-}" == "--it" ]]; then
  if [[ -n "$running_id" ]]; then
    echo "Error: A container from $IMAGE_NAME is already running (ID: $running_id)."
    echo "Stop it with: docker kill $running_id"
    exit 1
  fi

  docker run -it --rm "${COMMON_OPTS[@]}" "$IMAGE_NAME"
else
  # Reuse existing container if not updated; otherwise start new
  if [[ -n "$running_id" ]]; then
    container_id="$running_id"
    echo "Reusing running container: $container_id"

    # Ask Docker which host port maps to container 8888
    mapped="$(docker port "$container_id" 8888/tcp 2>/dev/null | head -n1 || true)"
    if [[ -n "$mapped" ]]; then
      # mapped looks like "127.0.0.1:49213" or "0.0.0.0:49213"
      HOST_PORT="${mapped##*:}"
    else
      # If container was started without publishing (unlikely here), fall back
      HOST_PORT=8888
    fi
  else
    container_id=$(docker run -d --rm "${COMMON_OPTS[@]}" "$IMAGE_NAME")
    echo "Container started: $container_id"
    echo "Waiting for Jupyter to start..."
  fi

  echo "Use '$0 stop' or 'docker kill $container_id' to stop it manually."

  # Grab the first URL with token from logs
  for i in {1..30}; do
    url=$(docker logs "$container_id" 2>&1 \
          | grep -Eo 'http://(127\.0\.0\.1|0\.0\.0\.0):8888/[^ ]*' \
          | head -n1 || true)
    if [[ -n "$url" ]]; then
      break
    fi
    sleep 2
  done

  if [[ -z "$url" ]]; then
    echo "Could not find Jupyter URL in logs. Run 'docker logs $container_id' manually."
    exit 1
  fi

  url=$(echo "$url" | sed -E "s#http://(127\.0\.0\.1|0\.0\.0\.0):[0-9]+/#http://localhost:${HOST_PORT}/#")
  open_in_browser "$url"
fi
