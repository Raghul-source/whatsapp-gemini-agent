# Setup and Execution Guide

## 1. gcloud Installer - Local Machine Prerequisite

Ignore this step if Google Cloud SDK is already installed.

```powershell
(New-Object Net.WebClient).DownloadFile("https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe", "$env:Temp\GoogleCloudSDKInstaller.exe")
& $env:Temp\GoogleCloudSDKInstaller.exe
```

Log in and set the project:

```bash
gcloud auth login
gcloud config set project framebyframe-agents-480720
```

## 2. Access The Cloud Server

Log in to the Google Cloud instance:

```bash
gcloud compute ssh instance-20260321-035448
```

Go to the project folder:

```bash
cd ~/whatsapp-agent
```

Confirmed server path:

```text
/home/raghul/whatsapp-agent
```

## 3. Clone And Access The Repository

If the project is not already present on the server, clone it from GitHub.

If it is already present, go inside the project folder and pull the latest code:

```bash
cd ~/whatsapp-agent
git status
git pull
```

## 4. Setup Python Environment

Install dependencies:

```bash
uv pip install -r requirements.txt
```

Check required packages:

```bash
uv run python -c "import uvicorn; print('uvicorn ok')"
uv run python -c "import fastapi; print('fastapi ok')"
uv run python -c "from vertexai.agent_engines import AdkApp; print('adkapp ok')"
uv run python -c "import main; print('main import ok')"
```

## 5. Configure Environment Variables

Create or edit the `.env` file:

```bash
nano .env
```

Required values:

```env
META_VERIFY_TOKEN=<your_meta_verify_token>
META_ACCESS_TOKEN=<your_meta_access_token>
META_PHONE_ID=<your_whatsapp_phone_number_id>

GCP_PROJECT_ID=framebyframe-agents-480720
LOCATION_ID=us-central1
AGENT_ENGINE_ID=<your_agent_runtime_id>
GOOGLE_GENAI_USE_VERTEXAI=TRUE
```

If `.env` is changed, restart the service:

```bash
sudo systemctl restart whatsapp-agent
```

## 6. Configure Google Cloud Authentication

Run Application Default Credentials login on the server:

```bash
gcloud auth application-default login
gcloud config set project framebyframe-agents-480720
sudo systemctl restart whatsapp-agent
```

## 7. Configure Nginx Route

This project uses the existing nginx config for `api.artelligence.ai`.

Confirmed route:

```nginx
location /whatsapp/ {
    proxy_pass http://127.0.0.1:8085/;
}
```

Confirmed webhook URL:

```text
https://api.artelligence.ai/whatsapp/webhook
```

Check nginx config:

```bash
sudo nginx -t
```

Restart nginx only if the route is changed:

```bash
sudo systemctl restart nginx
```

## 8. Create And Start The Background Service

Service file:

```bash
sudo nano /etc/systemd/system/whatsapp-agent.service
```

Current service configuration:

```ini
[Unit]
Description=WhatsApp Gemini Agent Service
After=network.target

[Service]
User=raghul
WorkingDirectory=/home/raghul/whatsapp-agent
Environment=PATH=/home/raghul/.local/bin:/usr/bin:/bin
ExecStart=/home/raghul/.local/bin/uv run uvicorn main:app --host 0.0.0.0 --port 8085
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Reload, enable, and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable whatsapp-agent
sudo systemctl start whatsapp-agent
```

Restart after code or `.env` changes:

```bash
sudo systemctl restart whatsapp-agent
```

## 9. Run And Verify The Application

Confirm the service is running:

```bash
sudo systemctl status whatsapp-agent
```

Verify the public webhook challenge:

```bash
curl "https://api.artelligence.ai/whatsapp/webhook?hub.mode=subscribe&hub.verify_token=token1&hub.challenge=12345"
```

Expected output:

```text
12345
```

Watch real-time logs:

```bash
journalctl -u whatsapp-agent -f
```

Successful WhatsApp message logs should include:

```text
ADK session found for <phone_number>
Message sent to WhatsApp! Meta API Status: 200
```
