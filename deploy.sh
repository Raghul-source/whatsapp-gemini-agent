#!/usr/bin/env bash
# Tells the system to use the Bash shell to run this script.
set -euo pipefail
# Safety feature: stops the script immediately if an error occurs or a required variable is missing.
export CLOUDSDK_COMPUTE_SSH=ssh
# Forces gcloud inside Git Bash to use standard ssh instead of Windows plink.exe.

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

GCP_INSTANCE="${GCP_INSTANCE:-}"
# Sets the Google Cloud VM instance name; if empty, the script tries to detect it from gcloud.
GCP_ZONE="${GCP_ZONE:-}"
# Sets the Google Cloud zone; if empty, the script tries to detect it from the selected VM.
GCP_PROJECT="${GCP_PROJECT:-}"
# Sets the Google Cloud project; if empty, the script reads the active gcloud project.
REPO_URL="${REPO_URL:-}"
# Defines the GitHub repository link; if empty, the script reads the current git remote URL.
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
USE_IAP_TUNNEL="${USE_IAP_TUNNEL:-true}"
# Uses Google Cloud IAP tunneling for SSH/SCP so deployment can work even when direct port 22 is blocked.
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# Defines the Linux systemd path where the service file must be saved.

require_command() {
  # Checks whether a required laptop command exists before deployment starts.
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $1"
    exit 1
  fi
}

require_command gcloud
require_command git

# Source: https://cloud.google.com/sdk/gcloud/reference/config/set
# Forces gcloud on Windows to use standard ssh instead of plink.exe for SSH/SCP operations.
gcloud config set compute/ssh_executable ssh >/dev/null 2>&1 || true

if command -v cmd.exe >/dev/null 2>&1 && [ -x "/c/Program Files/Git/usr/bin/ssh.exe" ]; then
  # Source: https://learn.microsoft.com/windows-server/administration/windows-commands/setx
  # Persists the Git Bash OpenSSH path for Windows gcloud so future terminals stop using plink.exe.
  cmd.exe /c setx CLOUDSDK_COMPUTE_SSH "C:\\Program Files\\Git\\usr\\bin\\ssh.exe" >/dev/null 2>&1 || true
  export CLOUDSDK_COMPUTE_SSH="C:\\Program Files\\Git\\usr\\bin\\ssh.exe"
fi

if [ -z "${GCP_PROJECT}" ]; then
  # Source: https://cloud.google.com/sdk/gcloud/reference/config/get-value
  # Detects the active Google Cloud project from the laptop's gcloud configuration.
  GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  if [ -z "${GCP_PROJECT}" ] || [ "${GCP_PROJECT}" = "(unset)" ]; then
    echo "ERROR: GCP_PROJECT is empty and no active gcloud project is configured."
    echo "Set a project with: gcloud config set project <project-id>"
    exit 1
  fi
fi

if [ -z "${REPO_URL}" ]; then
  # Source: https://git-scm.com/docs/git-config
  # Detects the GitHub repository URL from the repo already downloaded on the laptop.
  REPO_URL="$(git config --get remote.origin.url || true)"
  if [ -z "${REPO_URL}" ]; then
    echo "ERROR: REPO_URL is empty and git remote origin was not found."
    exit 1
  fi
fi

if [ -z "${GCP_INSTANCE}" ] || [ -z "${GCP_ZONE}" ]; then
  # Source: https://cloud.google.com/sdk/gcloud/reference/compute/instances/list
  # Finds available Compute Engine VM names and zones from the selected project.
  VM_LIST="$(gcloud compute instances list --project "${GCP_PROJECT}" --format='value(name,zone)' 2>/dev/null || true)"
  if [ -z "${VM_LIST}" ]; then
    echo "ERROR: No Compute Engine VM instances found in project: ${GCP_PROJECT}"
    exit 1
  fi

  if [ -n "${GCP_INSTANCE}" ] && [ -z "${GCP_ZONE}" ]; then
    GCP_ZONE="$(printf '%s\n' "${VM_LIST}" | awk -v instance="${GCP_INSTANCE}" '$1 == instance { print $2; exit }')"
    if [ -z "${GCP_ZONE}" ]; then
      echo "ERROR: Could not detect zone for VM instance: ${GCP_INSTANCE}"
      exit 1
    fi
  elif [ -z "${GCP_INSTANCE}" ] && [ -z "${GCP_ZONE}" ]; then
    VM_COUNT="$(printf '%s\n' "${VM_LIST}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    if [ "${VM_COUNT}" != "1" ]; then
      echo "ERROR: More than one VM found. Please set GCP_INSTANCE in deploy.env."
      printf '%s\n' "${VM_LIST}"
      exit 1
    fi
    GCP_INSTANCE="$(printf '%s\n' "${VM_LIST}" | awk '{ print $1; exit }')"
    GCP_ZONE="$(printf '%s\n' "${VM_LIST}" | awk '{ print $2; exit }')"
  elif [ -z "${GCP_INSTANCE}" ] && [ -n "${GCP_ZONE}" ]; then
    ZONE_VM_LIST="$(printf '%s\n' "${VM_LIST}" | awk -v zone="${GCP_ZONE}" '$2 == zone { print $1 }')"
    ZONE_VM_COUNT="$(printf '%s\n' "${ZONE_VM_LIST}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    if [ "${ZONE_VM_COUNT}" != "1" ]; then
      echo "ERROR: Could not uniquely detect VM in zone: ${GCP_ZONE}"
      printf '%s\n' "${VM_LIST}"
      exit 1
    fi
    GCP_INSTANCE="$(printf '%s\n' "${ZONE_VM_LIST}" | awk '{ print $1; exit }')"
  fi
fi

# Source: https://cloud.google.com/sdk/gcloud/reference/compute/instances/describe
# Checks that the selected VM exists, is running, and has an external IP before deployment starts.
VM_INFO="$(gcloud compute instances describe "${GCP_INSTANCE}" \
  --zone "${GCP_ZONE}" \
  --project "${GCP_PROJECT}" \
  --format='value(status,networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"

if [ -z "${VM_INFO}" ]; then
  echo "ERROR: VM not found or not accessible."
  echo "Check project, zone, instance name, and your Google Cloud permission."
  exit 1
fi

read -r VM_STATUS VM_EXTERNAL_IP <<EOF
${VM_INFO}
EOF

if [ "${VM_STATUS}" != "RUNNING" ]; then
  echo "ERROR: VM is not running. Current status: ${VM_STATUS}"
  exit 1
fi

if [ -z "${VM_EXTERNAL_IP}" ]; then
  echo "ERROR: VM has no external IP, so this laptop cannot connect with normal SSH/SCP."
  exit 1
fi

# Source: https://cloud.google.com/sdk/gcloud/reference/compute/firewall-rules/list
# Checks whether the project has a firewall rule that allows SSH on TCP port 22.
SSH_FIREWALL_RULES="$(gcloud compute firewall-rules list \
  --project "${GCP_PROJECT}" \
  --filter='allowed.tcp:22' \
  --format='value(name)' 2>/dev/null || true)"

if [ -z "${SSH_FIREWALL_RULES}" ]; then
  echo "WARNING: No firewall rule allowing TCP port 22 was found."
  echo "Using IAP tunnel mode to avoid direct SSH through the public firewall."
fi

GCLOUD_TUNNEL_ARGS=()
if [ "${USE_IAP_TUNNEL}" = "true" ]; then
  GCLOUD_TUNNEL_ARGS=(--tunnel-through-iap)

  # Source: https://cloud.google.com/iap/docs/using-tcp-forwarding#create-firewall-rule
  # Ensures Google IAP can reach SSH on the VM through TCP port 22.
  IAP_FIREWALL_RULE="allow-iap-ssh"
  if ! gcloud compute firewall-rules describe "${IAP_FIREWALL_RULE}" --project "${GCP_PROJECT}" >/dev/null 2>&1; then
    echo "Creating firewall rule for Google IAP SSH tunnel..."
    if ! gcloud compute firewall-rules create "${IAP_FIREWALL_RULE}" \
      --project "${GCP_PROJECT}" \
      --direction=INGRESS \
      --action=ALLOW \
      --rules=tcp:22 \
      --source-ranges=35.235.240.0/20 >/dev/null 2>&1; then
      echo "ERROR: Could not create IAP firewall rule."
      echo "Reason: your Google Cloud account may not have firewall admin permission."
      exit 1
    fi
  fi
fi

# Source: https://cloud.google.com/sdk/gcloud/reference/compute/ssh
# Tests SSH connectivity before uploading files so failures show a clear root cause.
echo "Checking SSH connectivity..."
if ! SSH_CHECK_OUTPUT="$(gcloud compute ssh "${GCP_INSTANCE}" \
  --zone "${GCP_ZONE}" \
  --project "${GCP_PROJECT}" \
  "${GCLOUD_TUNNEL_ARGS[@]}" \
  --command 'echo SSH_OK' 2>&1)"; then
  echo "ERROR: Could not connect to the VM using SSH."
  if printf '%s\n' "${SSH_CHECK_OUTPUT}" | grep -qi 'Connection timed out'; then
    echo "Reason: network timeout. IAP tunneling may be blocked, not enabled, or not allowed for your account."
  elif printf '%s\n' "${SSH_CHECK_OUTPUT}" | grep -qi 'Permission denied'; then
    echo "Reason: SSH permission denied. Your Google Cloud account or SSH key is not allowed."
  elif printf '%s\n' "${SSH_CHECK_OUTPUT}" | grep -qi 'not found\|Could not fetch resource'; then
    echo "Reason: wrong project, zone, or instance name."
  else
    echo "Reason: SSH pre-check failed. Details:"
    printf '%s\n' "${SSH_CHECK_OUTPUT}"
  fi
  exit 1
fi

echo "GCP instance : ${GCP_INSTANCE}"
echo "GCP zone     : ${GCP_ZONE}"
echo "GCP project  : ${GCP_PROJECT}"
echo "VM external IP: ${VM_EXTERNAL_IP}"
echo "Install path : ${APP_DIR}"
echo "Service name : ${SERVICE_NAME}"
echo "IAP tunnel   : ${USE_IAP_TUNNEL}"
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
  --project "${GCP_PROJECT}" \
  "${GCLOUD_TUNNEL_ARGS[@]}"

REMOTE_DEPLOY_SCRIPT="$(mktemp)"
# Source: https://www.gnu.org/software/coreutils/manual/html_node/mktemp-invocation.html
# Creates a temporary local script file so gcloud prompts and server commands use separate channels.
trap 'rm -f "${REMOTE_DEPLOY_SCRIPT}"' EXIT
# Removes the temporary local script after deployment finishes or fails.

cat >"${REMOTE_DEPLOY_SCRIPT}" <<REMOTE_SCRIPT
# Builds the remote install script locally, then uploads and runs it on the VM.
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

# Source: https://docs.python.org/3/library/venv.html
# Creates a Python virtual environment inside /opt/whatsapp-agent so runtime tools stay with the app.
if [ ! -d ".venv" ]; then
  python3 -m venv .venv
# Creates an isolated Python virtual environment under the /opt app folder if one does not already exist.
fi

# Source: https://pip.pypa.io/en/stable/user_guide/#requirements-files
# Installs Python dependencies from requirements.txt into the project virtual environment.
.venv/bin/python -m pip install -r requirements.txt
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
Environment=PATH=\${APP_DIR}/.venv/bin:/usr/bin:/bin
ExecStart=\${APP_DIR}/.venv/bin/uvicorn \${APP_MODULE} --host \${APP_HOST} --port \${APP_PORT}
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

# Source: https://cloud.google.com/sdk/gcloud/reference/compute/scp
# Uploads the generated remote install script to /tmp on the VM.
gcloud compute scp "${REMOTE_DEPLOY_SCRIPT}" "${GCP_INSTANCE}:/tmp/${SERVICE_NAME}-deploy.sh" \
  --zone "${GCP_ZONE}" \
  --project "${GCP_PROJECT}" \
  "${GCLOUD_TUNNEL_ARGS[@]}"

# Source: https://cloud.google.com/sdk/gcloud/reference/compute/ssh
# Runs the uploaded install script on the VM without manually logging in to the server.
gcloud compute ssh "${GCP_INSTANCE}" \
  --zone "${GCP_ZONE}" \
  --project "${GCP_PROJECT}" \
  "${GCLOUD_TUNNEL_ARGS[@]}" \
  --command "bash /tmp/${SERVICE_NAME}-deploy.sh"
