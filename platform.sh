#!/usr/bin/env bash

set -o nounset # exit if a variable is not set
set -o errexit # exit for any command failure

# text color escape codes
blue_text='\033[94m'
green_text='\033[32m'
red_text='\033[31m'
default_text='\033[39m'
yellow_text='\033[33m'

# Function to configure Docker proxy settings
configure_docker_proxy() {
  echo -e "${blue_text}Configuring Docker proxy settings...${default_text}"
  
  # Create or update Docker daemon config
  local docker_config_dir="$HOME/.docker"
  local docker_config_file="$docker_config_dir/config.json"
  
  # Create directory if it doesn't exist
  mkdir -p "$docker_config_dir"
  
  # Check if proxy settings exist in environment
  if [ -n "${http_proxy:-}" ] || [ -n "${https_proxy:-}" ]; then
    echo -e "${blue_text}Found proxy settings in environment${default_text}"
    
    # Create or update config.json
    if [ ! -f "$docker_config_file" ]; then
      echo '{}' > "$docker_config_file"
    fi
    
    # Update proxy settings
    local http_proxy_value="${http_proxy:-}"
    local https_proxy_value="${https_proxy:-}"
    local no_proxy_value="${no_proxy:-}"
    
    # Use jq if available, otherwise use sed
    if command -v jq &> /dev/null; then
      jq --arg http "$http_proxy_value" \
         --arg https "$https_proxy_value" \
         --arg noproxy "$no_proxy_value" \
         '.proxies.default = {
           "httpProxy": $http,
           "httpsProxy": $https,
           "noProxy": $noproxy
         }' "$docker_config_file" > "$docker_config_file.tmp" && \
      mv "$docker_config_file.tmp" "$docker_config_file"
    else
      # Basic sed fallback (less robust but works for simple cases)
      sed -i.bak "s/\"proxies\":.*}/\"proxies\":{\"default\":{\"httpProxy\":\"$http_proxy_value\",\"httpsProxy\":\"$https_proxy_value\",\"noProxy\":\"$no_proxy_value\"}}/" "$docker_config_file"
    fi
    
    echo -e "${green_text}Docker proxy settings configured${default_text}"
  else
    echo -e "${yellow_text}No proxy settings found in environment${default_text}"
  fi
}

# Function to retry a command
retry_command() {
  local max_attempts=3
  local attempt=1
  local delay=5
  
  while [ $attempt -le $max_attempts ]; do
    echo -e "${blue_text}Attempt $attempt of $max_attempts...${default_text}"
    
    if "$@"; then
      return 0
    fi
    
    echo -e "${yellow_text}Command failed. Retrying in $delay seconds...${default_text}"
    sleep $delay
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
  
  echo -e "${red_text}Command failed after $max_attempts attempts${default_text}"
  return 1
}

# Function to validate and setup volumes
setup_volumes() {
  echo -e "${blue_text}Setting up required volumes...${default_text}"
  
  # Get the absolute path of the workspace
  local workspace_path=$(pwd)
  
  # Create tool registry directory if it doesn't exist
  local tool_registry_path="$workspace_path/tool-registry"
  if [ ! -d "$tool_registry_path" ]; then
    echo -e "${blue_text}Creating tool registry directory...${default_text}"
    mkdir -p "$tool_registry_path"
  fi
  
  # Create tool registry config directory
  local tool_registry_config_path="$tool_registry_path/tool_registry_config"
  if [ ! -d "$tool_registry_config_path" ]; then
    echo -e "${blue_text}Creating tool registry config directory...${default_text}"
    mkdir -p "$tool_registry_config_path"
  fi
  
  # Create workflow data directory if it doesn't exist
  local workflow_data_path="$workspace_path/docker/workflow_data"
  if [ ! -d "$workflow_data_path" ]; then
    echo -e "${blue_text}Creating workflow data directory...${default_text}"
    mkdir -p "$workflow_data_path"
  fi
  
  # Export the tool registry path for Docker Compose
  export TOOL_REGISTRY_CONFIG_SRC_PATH="$tool_registry_config_path"
  
  echo -e "${green_text}Volume directories created${default_text}"
}

# Function to run docker compose with environment variables and retry logic
run_docker_compose() {
  local compose_file="docker/docker-compose.yaml"
  local command="$1"
  shift
  
  # Ensure environment variables are set
  ensure_env_vars
  
  # Setup volumes
  setup_volumes
  
  # Setup platform
  setup_platform
  
  # Run docker compose with retry logic and platform override if it exists
  if [ -f "docker/docker-compose.override.yaml" ]; then
    retry_command docker compose -f "$compose_file" -f "docker/docker-compose.override.yaml" "$command" "$@"
  else
    retry_command docker compose -f "$compose_file" "$command" "$@"
  fi
}

# Function to pull Docker images with retry logic
pull_docker_images() {
  echo -e "${blue_text}Pulling Docker images...${default_text}"
  
  # Get the version from environment
  local version="${VERSION:-latest}"
  
  # List of images to pull
  local images=(
    "unstract/backend:$version"
    "unstract/frontend:$version"
    "unstract/platform-service:$version"
    "unstract/prompt-service:$version"
    "unstract/x2text-service:$version"
    "unstract/runner:$version"
  )
  
  # Get platform for pulling
  local platform=""
  if [ "$(uname -m)" = "arm64" ]; then
    platform="--platform linux/amd64"
  fi
  
  # Pull each image with retry logic
  for image in "${images[@]}"; do
    echo -e "${blue_text}Pulling $image...${default_text}"
    retry_command docker pull $platform "$image"
  done
}

# Function to detect architecture and set platform
setup_platform() {
  echo -e "${blue_text}Detecting architecture and setting up platform...${default_text}"
  
  # Detect architecture
  local arch=$(uname -m)
  echo -e "${blue_text}Detected architecture: $arch${default_text}"
  
  # Create platform-specific override if on ARM64
  if [ "$arch" = "arm64" ]; then
    echo -e "${blue_text}ARM64 architecture detected. Creating platform override...${default_text}"
    
    # Create docker-compose.override.yaml with all services
    cat > docker/docker-compose.override.yaml << 'EOF'
services:
  backend:
    platform: linux/amd64
    image: unstract/backend:${VERSION:-latest}
  frontend:
    platform: linux/amd64
    image: unstract/frontend:${VERSION:-latest}
  platform-service:
    platform: linux/amd64
    image: unstract/platform-service:${VERSION:-latest}
  prompt-service:
    platform: linux/amd64
    image: unstract/prompt-service:${VERSION:-latest}
  x2text-service:
    platform: linux/amd64
    image: unstract/x2text-service:${VERSION:-latest}
  runner:
    platform: linux/amd64
    image: unstract/runner:${VERSION:-latest}
  worker:
    platform: linux/amd64
    image: unstract/backend:${VERSION:-latest}
  worker-api-deployment:
    platform: linux/amd64
    image: unstract/backend:${VERSION:-latest}
  worker-api-file-processing:
    platform: linux/amd64
    image: unstract/backend:${VERSION:-latest}
  worker-file-processing:
    platform: linux/amd64
    image: unstract/backend:${VERSION:-latest}
  worker-logging:
    platform: linux/amd64
    image: unstract/backend:${VERSION:-latest}
  celery-beat:
    platform: linux/amd64
    image: unstract/backend:${VERSION:-latest}
EOF
    
    echo -e "${green_text}Created platform override for ARM64${default_text}"
  else
    echo -e "${blue_text}Using default platform configuration${default_text}"
    # Remove override if it exists
    rm -f docker/docker-compose.override.yaml
  fi
}

# Function to ensure environment variables are set
ensure_env_vars() {
  echo -e "${blue_text}Ensuring environment variables are set...${default_text}"
  
  # Check if .env file exists, if not create from sample
  if [ ! -f ".env" ]; then
    if [ -f "docker/sample.env" ]; then
      echo -e "${blue_text}Creating .env file from sample...${default_text}"
      cp docker/sample.env .env
    else
      echo -e "${yellow_text}Warning: sample.env not found${default_text}"
    fi
  fi
  
  # Get the latest version from git tags if available
  local version=$(git describe --tags --abbrev=0 2>/dev/null || echo "latest")
  export VERSION="$version"
  
  # Set default values for required variables
  export WORKER_API_DEPLOYMENTS_AUTOSCALE=${WORKER_API_DEPLOYMENTS_AUTOSCALE:-"4,1"}
  export WORKER_LOGGING_AUTOSCALE=${WORKER_LOGGING_AUTOSCALE:-"4,1"}
  export WORKER_AUTOSCALE=${WORKER_AUTOSCALE:-"4,1"}
  export WORKER_FILE_PROCESSING_AUTOSCALE=${WORKER_FILE_PROCESSING_AUTOSCALE:-"4,1"}
  export WORKER_API_FILE_PROCESSING_AUTOSCALE=${WORKER_API_FILE_PROCESSING_AUTOSCALE:-"4,1"}
  
  # Export all variables from .env file
  if [ -f ".env" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]]; then
        export "$line"
      fi
    done < ".env"
  fi
  
  echo -e "${green_text}Environment variables set${default_text}"
}

# Function to display help
display_help() {
  echo "Platform Management Script"
  echo
  echo "Usage: ./platform.sh [command]"
  echo
  echo "Commands:"
  echo "  start             Start the platform using run-platform.sh"
  echo "  stop              Stop all services and clean up"
  echo "  restart-frontend  Restart the frontend service with clean build"
  echo "  restart-backend   Restart the backend services with clean build"
  echo "  help              Display this help message"
  echo
}

# Function to stop and clean up all services
stop_platform() {
  echo -e "${blue_text}Stopping all services...${default_text}"
  
  # Stop all containers using the helper function
  run_docker_compose down --remove-orphans
  
  # Remove all containers (including stopped ones)
  docker rm -f $(docker ps -aq) 2>/dev/null || true
  
  # Remove all volumes
  docker volume rm $(docker volume ls -q) 2>/dev/null || true
  
  # Remove all images
  docker rmi -f $(docker images -q) 2>/dev/null || true
  
  # Clean up temp and build files
  echo -e "${blue_text}Cleaning up temporary and build files...${default_text}"
  
  # Clean frontend
  rm -rf frontend/node_modules
  rm -rf frontend/build
  rm -rf frontend/.next
  rm -rf frontend/.cache
  
  # Clean backend
  find backend -type d -name "__pycache__" -exec rm -rf {} +
  find backend -type d -name "*.egg-info" -exec rm -rf {} +
  find backend -type d -name ".pytest_cache" -exec rm -rf {} +
  find backend -type d -name ".coverage" -exec rm -rf {} +
  
  # Clean docker data
  rm -rf docker/workflow_data/*
  
  # Clean configuration files
  rm -f docker/docker-compose.volumes.yaml
  rm -f docker/docker-compose.override.yaml
  
  echo -e "${green_text}Platform stopped and cleaned successfully!${default_text}"
}

# Function to restart frontend
restart_frontend() {
  echo -e "${blue_text}Stopping frontend service...${default_text}"
  run_docker_compose stop frontend
  run_docker_compose rm -f frontend
  
  echo -e "${blue_text}Cleaning frontend build files...${default_text}"
  rm -rf frontend/node_modules
  rm -rf frontend/build
  rm -rf frontend/.next
  rm -rf frontend/.cache
  
  echo -e "${blue_text}Installing frontend dependencies...${default_text}"
  cd frontend
  npm install
  
  echo -e "${blue_text}Building frontend...${default_text}"
  npm run build
  
  echo -e "${blue_text}Starting frontend service...${default_text}"
  cd ..
  run_docker_compose up -d frontend
  
  echo -e "${green_text}Frontend restarted successfully!${default_text}"
}

# Function to restart backend services
restart_backend() {
  echo -e "${blue_text}Setting up platform configuration...${default_text}"
  setup_platform
  
  echo -e "${blue_text}Stopping backend services...${default_text}"
  run_docker_compose stop backend worker worker-logging worker-api-deployment worker-file-processing worker-api-file-processing celery-beat
  run_docker_compose rm -f backend worker worker-logging worker-api-deployment worker-file-processing worker-api-file-processing celery-beat
  
  echo -e "${blue_text}Cleaning backend build files...${default_text}"
  # Clean Python cache files
  find backend -type d -name "__pycache__" -exec rm -rf {} +
  find backend -type d -name "*.egg-info" -exec rm -rf {} +
  find backend -type d -name ".pytest_cache" -exec rm -rf {} +
  find backend -type d -name ".coverage" -exec rm -rf {} +
  
  # Clean virtual environment if it exists
  if [ -d "backend/.venv" ]; then
    echo -e "${blue_text}Removing existing virtual environment...${default_text}"
    rm -rf backend/.venv
  fi
  
  echo -e "${blue_text}Setting up Python virtual environment...${default_text}"
  cd backend
  python3 -m venv .venv
  source .venv/bin/activate
  
  echo -e "${blue_text}Installing backend dependencies...${default_text}"
  pip install -r requirements.txt
  
  echo -e "${blue_text}Building backend...${default_text}"
  pip install -e .
  
  echo -e "${blue_text}Starting backend services...${default_text}"
  cd ..
  run_docker_compose up -d backend worker worker-logging worker-api-deployment worker-file-processing worker-api-file-processing celery-beat
  
  echo -e "${green_text}Backend services restarted successfully!${default_text}"
}

# Main script logic
case "${1:-}" in
  "start")
    echo -e "${blue_text}Starting platform...${default_text}"
    configure_docker_proxy
    ensure_env_vars
    setup_platform
    pull_docker_images
    ./run-platform.sh
    ;;
  "stop")
    stop_platform
    ;;
  "restart-frontend")
    configure_docker_proxy
    restart_frontend
    ;;
  "restart-backend")
    configure_docker_proxy
    restart_backend
    ;;
  "help"|"")
    display_help
    ;;
  *)
    echo -e "${red_text}Unknown command: $1${default_text}"
    display_help
    exit 1
    ;;
esac 