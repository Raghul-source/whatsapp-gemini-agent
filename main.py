# ==============================================================================
# OFFICIAL GOOGLE & META DOCUMENTATION REFERRED:
# 1. Official Agent Platform Samples Repo: https://github.com/Google-Cloud-AI/agent-platform
# 2. ADK Python Samples Setup: https://github.com/google/adk-samples/tree/main/python
#    Used setup ideas: Python ADK project structure, .env configuration,
#    Google Cloud project/location variables, and separate agent definition.
# ==============================================================================

import os

# Source: https://fastapi.tiangolo.com/tutorial/first-steps/
# Source: https://fastapi.tiangolo.com/tutorial/background-tasks/
from fastapi import BackgroundTasks, FastAPI, Request, HTTPException
from fastapi.responses import PlainTextResponse
# Used for FastAPI routes/request handling and BackgroundTasks so Meta gets 200 OK quickly while the agent reply runs after.

# Source: https://saurabh-kumar.com/python-dotenv/
from dotenv import load_dotenv
# Used to load values from the .env file into Python so os.getenv(...) can read tokens, phone ID, project ID, and related settings.

# Source: https://requests.readthedocs.io/en/latest/user/quickstart/#make-a-request
import requests
# Used to send HTTP requests from Python; here it sends the agent's final reply to Meta WhatsApp API using requests.post(...).


# We import the whatsapp_agent variable from agent.py to connect this webhook with our ADK agent.
from agent import whatsapp_agent


# Source: https://cloud.google.com/vertex-ai/docs/python-sdk/use-vertex-ai-python-sdk
import vertexai
# Used to initialize the Vertex AI SDK with the project and location from .env before AdkApp starts.


# ==============================================================================
# ADK App connects our ADK agent to Agent Platform session handling.
from vertexai.agent_engines import AdkApp
# ==============================================================================

# Source: https://saurabh-kumar.com/python-dotenv/#getting-started
# Load environment variables.
load_dotenv()

def get_required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value

META_VERIFY_TOKEN = get_required_env("META_VERIFY_TOKEN")
META_ACCESS_TOKEN = get_required_env("META_ACCESS_TOKEN")
META_PHONE_ID = get_required_env("META_PHONE_ID")
GCP_PROJECT_ID = get_required_env("GCP_PROJECT_ID")
LOCATION_ID = get_required_env("LOCATION_ID")
AGENT_ENGINE_ID = get_required_env("AGENT_ENGINE_ID")

# Source: https://google.github.io/adk-docs/get-started/quickstart/
# Tell ADK/GenAI to use the Google Cloud Vertex AI backend.
os.environ.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "TRUE")

# Source: https://cloud.google.com/vertex-ai/docs/python-sdk/use-vertex-ai-python-sdk
# Give Vertex AI / AdkApp the project and location loaded from .env.
vertexai.init(project=GCP_PROJECT_ID, location=LOCATION_ID)

# Source: https://fastapi.tiangolo.com/tutorial/first-steps/
app = FastAPI(title="WhatsApp Gemini Agent Webhook")

APP_NAME = "whatsapp_gemini_agent"

# Source: https://docs.cloud.google.com/agent-builder/agent-engine/develop/adk
# Runtime background: https://github.com/GoogleCloudPlatform/generative-ai/blob/main/gemini/agent-engine/intro_agent_engine.ipynb
# Explains the managed Agent Runtime idea for deploying and serving agents.
# Initialize the ADK App. The official AdkApp template uses local sessions while
# testing locally and managed Agent Platform sessions after deployment.
# This script connects our AI agent to the web to process incoming messages. It automatically remembers separate chat histories for every WhatsApp user based on their phone number.
adk_app = AdkApp(
    agent=whatsapp_agent,
    app_name=APP_NAME
)

# ==============================================================================

# Depending on the phone number, retrieve the existing session or create a new one.
async def ensure_user_session(phone_number: str):
    # Source: https://google.github.io/adk-docs/sessions/session/
    # A session is scoped by user_id and session_id so each WhatsApp user is isolated.
    try:
        session = await adk_app.async_get_session(
            user_id=phone_number,
            session_id=phone_number
        )
        if session:
            print(f"ADK session found for {phone_number}")
            return session
        print(f"ADK session lookup returned empty for {phone_number}")
    except Exception as e:
        print(f"ADK get_session failed for {phone_number}: {type(e).__name__}: {e}")

    try:
        session = await adk_app.async_create_session(
            user_id=phone_number,
            session_id=phone_number
        )
        print(f"ADK session created for {phone_number}")
        return session
    except Exception as e:
        print(f"ADK create_session failed for {phone_number}: {type(e).__name__}: {e}")
        print(f"ADK retrying get_session after create failure for {phone_number}")
        session = await adk_app.async_get_session(
            user_id=phone_number,
            session_id=phone_number
        )
        print(f"ADK session found after retry for {phone_number}")
        return session

# Source: https://docs.cloud.google.com/python/docs/reference/vertexai/latest/vertexai.agent_engines.AdkApp
# Extract only the response information from ADK events before sending it to Meta.
def extract_event_text(event) -> str:
    if isinstance(event, dict):
        content = event.get("content") or {}
        parts = content.get("parts") or []
        return "".join(part.get("text", "") for part in parts if isinstance(part, dict))

    if getattr(event, "output", None):
        return event.output

    if getattr(event, "content", None) and event.content.parts:
        return "".join(
            part.text for part in event.content.parts if getattr(part, "text", None)
        )

    return ""

async def process_agent_and_reply(phone_number: str, message_text: str):
    try:
        # ==============================================================================
        # 4. Correct Official State Management (The "Memory" Rule)
        # We use AdkApp sessions, passing the phone number as 'user_id' and
        # 'session_id' to isolate each WhatsApp user's state.
        await ensure_user_session(phone_number)
        
        # We must gather the async events to get the final message text
        final_response = ""
        async for event in adk_app.async_stream_query(
            message=message_text,
            user_id=phone_number,
            session_id=phone_number
        ):
            event_text = extract_event_text(event)
            if event_text:
                final_response = event_text
        
        print(f"Isolated ADK Agent response for {phone_number}: {final_response}")
        
        # ==============================================================================
        # OFFICIAL SOURCE: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/send-messages
        # REQUESTS SOURCE: https://requests.readthedocs.io/en/latest/user/quickstart/#more-complicated-post-requests
        # 5. Send the AI's response back to the user's WhatsApp
        # ==============================================================================
        meta_url = f"https://graph.facebook.com/v18.0/{META_PHONE_ID}/messages"
        headers = {
            "Authorization": f"Bearer {META_ACCESS_TOKEN}",
            "Content-Type": "application/json"
        }
        payload = {
            "messaging_product": "whatsapp",
            "to": phone_number,
            "type": "text",
            "text": {"body": final_response}
        }

        # Fire the HTTP POST request across the internet to Meta
        send_response = requests.post(meta_url, headers=headers, json=payload)
        print(f"Message sent to WhatsApp! Meta API Status: {send_response.status_code}")
        # ==============================================================================
    except Exception as e:
        print(f"Error in background task: {e}")


# ==============================================================================
# OFFICIAL SOURCE: https://developers.facebook.com/docs/graph-api/webhooks/getting-started
# PURPOSE: The mandatory "WhatsApp door" and one-time security handshake.
# - Meta knocks with our password (META_VERIFY_TOKEN) and a random code (hub.challenge).
# - We echo the challenge back to prove our server is online, secure, and owned by us.
# - This prevents strangers from hijacking the WhatsApp business number.
# ==============================================================================
@app.get("/webhook")
def verify_webhook(request: Request):
    mode = request.query_params.get("hub.mode")
    token = request.query_params.get("hub.verify_token")
    challenge = request.query_params.get("hub.challenge")

    if mode and token:
        if mode == "subscribe" and token == META_VERIFY_TOKEN:
            return PlainTextResponse(content=str(challenge))
        else:
            raise HTTPException(status_code=403, detail="Verification token mismatch")
    
    raise HTTPException(status_code=400, detail="Missing parameters")


# ==============================================================================
# OFFICIAL SOURCE: https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples
# PURPOSE: Translates Meta's raw nested JSON payload into working Python code.
# JSON EXTRACTION MAP:
# - entry[0]   : Meta puts everything inside an array called entry. We grab the first item.
# - changes[0] : Inside entry, there is an array called changes. We dig into the first item.
# - value      : Inside changes, there is an object called value. We open it.
# - messages   : Inside value, we finally find the messages array.
# - from / text: We pull the sender's phone number and the actual text they typed.
# ==============================================================================
@app.post("/webhook")
async def receive_message(request: Request, background_tasks: BackgroundTasks):
    body = await request.json()

    try:
        entry = body.get("entry", [])[0]
        changes = entry.get("changes", [])[0]
        value = changes.get("value", {})
        messages = value.get("messages", [])
        
        if not messages:
            return PlainTextResponse("Not a message payload", status_code=200)
            
        message = messages[0]
        
        # Data Extraction
        phone_number = message.get("from")
        message_text = message.get("text", {}).get("body")

        if not phone_number or not message_text:
            return PlainTextResponse("Missing text or phone number", status_code=200)

        background_tasks.add_task(process_agent_and_reply, phone_number, message_text)

        return PlainTextResponse("OK", status_code=200)

    except Exception as e:
        print(f"Error parsing webhook: {e}")
        return PlainTextResponse("Error", status_code=500)
