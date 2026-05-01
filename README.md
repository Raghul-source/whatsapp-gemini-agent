# WhatsApp Gemini Agent

A webhook service that connects WhatsApp Cloud API messages to a Gemini Enterprise Agent Platform ADK agent.

The app receives incoming WhatsApp messages, forwards them to the ADK agent, keeps each user's session separate by phone number, and sends the generated reply back to WhatsApp.

## Features

- WhatsApp Cloud API webhook verification and message handling.
- Gemini Enterprise Agent Platform ADK agent integration.
- Per-user conversation state using the sender's WhatsApp phone number.
- Background message processing so Meta receives a quick `200 OK`.
- Source links placed in code comments near the related implementation.

## Project Structure

```text
whatsapp-gemini-agent/
├── agent.py          # ADK agent definition
├── main.py           # FastAPI webhook server and ADK App flow
├── requirements.txt  # Python dependencies
├── .env.example      # Environment variable template
└── README.md
```

## How It Works

1. Meta sends an incoming WhatsApp message to `POST /webhook`.
2. `main.py` extracts the sender phone number and message text.
3. The app retrieves or creates a session for that phone number.
4. The message is streamed through the ADK agent using `AdkApp`.
5. The final response text is extracted from ADK events.
6. The response is sent back to the user through the Meta WhatsApp Cloud API.

## Session Handling

Each WhatsApp phone number is used as both the ADK `user_id` and `session_id`:

```python
user_id=phone_number
session_id=phone_number
```

This keeps one user's conversation state separate from every other user.

## Environment Variables

Create a `.env` file using `.env.example`:

```env
META_VERIFY_TOKEN=
META_ACCESS_TOKEN=
META_PHONE_ID=

GCP_PROJECT_ID=
LOCATION_ID=
AGENT_ENGINE_ID=
GOOGLE_GENAI_USE_VERTEXAI=TRUE
```

Never commit `.env`. It contains private Meta and Google Cloud credentials.

## Install

```cmd
uv pip install -r requirements.txt
```

## Run Locally

```cmd
uv run uvicorn main:app --port 8080
```

## Run On Server

```bash
uv run uvicorn main:app --host 0.0.0.0 --port 8085
```

For complete server setup, environment updates, Meta webhook configuration, background service commands, and log checks, see `SETUP.md`.

## Webhook Routes

- `GET /webhook` - Verifies the webhook with Meta.
- `POST /webhook` - Receives WhatsApp message events.

## Expected Logs

Successful message handling should look similar to this:

```text
ADK session found for <phone_number>
Isolated ADK Agent response for <phone_number>: <agent reply>
Message sent to WhatsApp! Meta API Status: 200
```

## References

- Gemini Enterprise Agent Platform samples: https://github.com/Google-Cloud-AI/agent-platform
- ADK Python samples: https://github.com/google/adk-samples/tree/main/python
- ADK sessions: https://google.github.io/adk-docs/sessions/session/
- AdkApp API reference: https://docs.cloud.google.com/python/docs/reference/vertexai/latest/vertexai.agent_engines.AdkApp
- FastAPI first steps: https://fastapi.tiangolo.com/tutorial/first-steps/
- FastAPI background tasks: https://fastapi.tiangolo.com/tutorial/background-tasks/
- python-dotenv: https://saurabh-kumar.com/python-dotenv/
- Requests POST usage: https://requests.readthedocs.io/en/latest/user/quickstart/#more-complicated-post-requests
- Meta webhook setup: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/set-up-webhooks
- Meta webhook payload examples: https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples
- Meta send messages: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/send-messages
