#!/usr/bin/env bash
# Tells the system to use the Bash shell to run this script.
set -euo pipefail
# Safety feature: stops the script immediately if an error occurs or a required variable is missing.

# ==============================================================================
# Deploy WhatsApp Gemini Agent from a laptop to the server.
#
# Usage:
#   cp deploy.env.example deploy.env
#   # edit deploy.env
#   chmod +x deploy.sh
#   ./deploy.sh
#
# Override values without deploy.env if needed:
#   GCP_INSTANCE=<vm-instance-name> GCP_ZONE=<zone> GCP_PROJECT=<project-id> ./deploy.sh
#   REPO_URL=https://github.com/Raghul-source/whatsapp-gemini-agent.git ./deploy.sh
# ==============================================================================

DEPLOY_CONFIG="${DEPLOY_CONFIG:-./deploy.env}"
# Defines the local input file that stores project/server-specific deployment values.
if [ -f "${DEPLOY_CONFIG}" ]; then
  # Source: https://www.gnu.org/software/bash/manual/bash.html#index-source
  # Loads deployment input values from deploy.env so the script can be reused across projects.
  # shellcheck disable=SC1090
  source "${DEPLOY_CONFIG}"
fi

GCP_INSTANCE="${GCP_INSTANCE:-instance-20260321-035448}"
# Sets the Google Cloud VM instance name to connect to.
GCP_ZONE="${GCP_ZONE:-us-central1-c}"
# Sets the Google Cloud zone where the VM exists.
GCP_PROJECT="${GCP_PROJECT:-framebyframe-agents-480720}"
# Sets the Google Cloud project that owns the VM.
REPO_URL="${REPO_URL:-https://github.com/Raghul-source/whatsapp-gemini-agent.git}"
# Defines the GitHub repository link used to download or update the code.
APP_DIR="${APP_DIR:-/opt/whatsapp-agent}"
# Sets the install destination under /opt so the app is not installed inside a personal login folder.
APP_USER="${APP_USER:-}"
# Defines the Linux user that runs the app; if empty, the script detects the remote login user automatically.
SERVICE_NAME="${SERVICE_NAME:-whatsapp-agent}"
# Defines the background service name used to start, stop, restart, and check the app.
APP_ENV_FILE="${APP_ENV_FILE:-./.env}"
# Defines the local env file to upload to the server as APP_DIR/.env.
APP_MODULE="${APP_MODULE:-main:app}"
# Defines the Python ASGI app loaded by uvicorn.
APP_HOST="${APP_HOST:-0.0.0.0}"
# Defines the host address uvicorn listens on.
APP_PORT="${APP_PORT:-8085}"
# Defines the port uvicorn listens on.
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# Defines the Linux systemd path where the service file must be saved.

echo "GCP instance : ${GCP_INSTANCE}"
echo "GCP zone     : ${GCP_ZONE}"
echo "GCP project  : ${GCP_PROJECT}"
echo "Install path : ${APP_DIR}"
echo "Service name : ${SERVICE_NAME}"
echo "App command  : uvicorn ${APP_MODULE} --host ${APP_HOST} --port ${APP_PORT}"

if [ ! -f "${APP_ENV_FILE}" ]; then
  echo "ERROR: Local env file not found: ${APP_ENV_FILE}"
  echo "Create it by copying .env.example to .env, then fill the real values."
  exit 1
fi

# Source: https://cloud.google.com/sdk/gcloud/reference/compute/scp
# Copies the local .env file to /tmp first because writing directly to /opt usually needs sudo.
gcloud compute scp "${APP_ENV_FILE}" "${GCP_INSTANCE}:/tmp/${SERVICE_NAME}.env" \
  --zone "${GCP_ZONE}" \
  --project "${GCP_PROJECT}"

# Source: https://cloud.google.com/sdk/gcloud/reference/compute/ssh
# Connects to the Google Cloud VM from this laptop and runs the full installation remotely.
gcloud compute ssh "${GCP_INSTANCE}" \
  --zone "${GCP_ZONE}" \
  --project "${GCP_PROJECT}" \
  --command "bash -s" <<REMOTE_SCRIPT
# Uses gcloud to connect to the VM and run everything below remotely, without manually logging in and typing each command.
set -euo pipefail

REPO_URL="${REPO_URL}"
APP_DIR="${APP_DIR}"
APP_USER="${APP_USER}"
SERVICE_NAME="${SERVICE_NAME}"
APP_MODULE="${APP_MODULE}"
APP_HOST="${APP_HOST}"
APP_PORT="${APP_PORT}"
SERVICE_FILE="${SERVICE_FILE}"

echo "Running remote deployment on \$(hostname)"

if [ -z "\${APP_USER}" ]; then
  APP_USER="\$(whoami)"
fi
echo "Service user : \${APP_USER}"

# Source: https://git-scm.com/docs/git-clone
# Source: https://git-scm.com/docs/git-pull
# Creates /opt/whatsapp-agent from GitHub if missing; otherwise updates it with git pull.
if [ ! -d "\${APP_DIR}/.git" ]; then
# Checks whether the repository is already installed in the target /opt folder.
  echo "Repository not found. Cloning into \${APP_DIR}..."
  sudo mkdir -p "\${APP_DIR}"
# Creates the target install folder if it does not already exist.
  sudo chown "\${APP_USER}:\${APP_USER}" "\${APP_DIR}"
# Gives the app user read/write permission for the install folder.
  git clone "\${REPO_URL}" "\${APP_DIR}"
# Downloads the project fresh from GitHub into /opt/whatsapp-agent.
else
  echo "Repository exists. Pulling latest code..."
  cd "\${APP_DIR}"
  git pull
# If the repository already exists, fetches the latest code updates.
fi

cd "\${APP_DIR}"

# Source: https://docs.astral.sh/uv/getting-started/installation/
# Installs uv on the server if it is not already available.
if ! command -v uv >/dev/null 2>&1; then
# Checks whether the uv Python package manager is installed on the server.
  echo "uv not found. Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
# Downloads and installs the uv package manager.
  export PATH="\${HOME}/.local/bin:\${PATH}"
fi

# Source: https://docs.astral.sh/uv/pip/environments/
# Creates a local .venv in /opt/whatsapp-agent if one does not already exist.
if [ ! -d ".venv" ]; then
  uv venv
# Creates an isolated Python virtual environment if one does not already exist.
fi

# Source: https://docs.astral.sh/uv/pip/packages/
# Installs Python dependencies from requirements.txt into the project virtual environment.
uv pip install -r requirements.txt
# Installs all Python packages required by the project.

# Source: https://man7.org/linux/man-pages/man1/install.1.html
# Moves the uploaded env file into /opt/whatsapp-agent/.env with restricted permissions.
sudo install -m 600 -o "\${APP_USER}" -g "\${APP_USER}" "/tmp/\${SERVICE_NAME}.env" "\${APP_DIR}/.env"
# Copies the laptop-provided env file into the app folder as .env so first-time install does not require manual server login.

# Source: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
# Writes the systemd service so the app runs in the background from /opt/whatsapp-agent.
sudo tee "\${SERVICE_FILE}" >/dev/null <<SERVICE_UNIT
# Creates or replaces the background service file with the instructions below.
[Unit]
Description=WhatsApp Gemini Agent Service
After=network.target

[Service]
User=\${APP_USER}
# Runs the app as the designated Linux user, not as root.
WorkingDirectory=\${APP_DIR}
# Runs the app from the /opt/whatsapp-agent project directory.
Environment=PATH=/home/\${APP_USER}/.local/bin:/usr/bin:/bin
ExecStart=/home/\${APP_USER}/.local/bin/uv run uvicorn \${APP_MODULE} --host \${APP_HOST} --port \${APP_PORT}
# Starts the FastAPI/Uvicorn backend using the configured app module, host, and port.
Restart=always
# Automatically restarts the app if it crashes.
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_UNIT

# Source: https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
# Reloads systemd, enables the service on boot, and restarts the app with the new code.
sudo systemctl daemon-reload
# Reloads systemd so it reads the new or updated service file.
sudo systemctl enable "\${SERVICE_NAME}"
# Enables the app to start automatically when the server reboots.
sudo systemctl restart "\${SERVICE_NAME}"
# Restarts the service immediately so it runs the newest code.

echo "Waiting for service startup..."
sleep 5

sudo systemctl status "\${SERVICE_NAME}" --no-pager || {
# Checks whether the service started successfully; if it failed, runs the error block below.
  echo "Service failed. Showing recent logs..."
  # Source: https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
  # Prints recent service logs for quick debugging when deployment fails.
  journalctl -u "\${SERVICE_NAME}" -n 50 --no-pager
# Prints the latest service logs back to the laptop terminal for debugging.
  exit 1
}

echo "Deployment completed successfully."
REMOTE_SCRIPT
