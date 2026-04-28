# ==============================================================================
# OFFICIAL GOOGLE & META DOCUMENTATION REFERRED:
# 1. ADK Quickstart: https://docs.cloud.google.com/gemini-enterprise-agent-platform/build/runtime/quickstart-adk?authuser=2
# 2. Meta Webhooks: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/set-up-webhooks
# 3. Web Server Infrastructure: https://fastapi.tiangolo.com/tutorial/first-steps/
# 4. Meta Webhook Setup Video: https://www.youtube.com/watch?v=N5LLmBtcfCs
# 5. ADK Session Management: https://adk.dev/run/resume-agents
# 6. Meta Send Message API: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/send-messages
# 7. Official Agent Platform Samples Repo: https://github.com/Google-Cloud-AI/agent-platform
# ==============================================================================

import os
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import PlainTextResponse
from dotenv import load_dotenv
import requests
from agent import whatsapp_agent

# ==============================================================================
# Snippet Source: https://docs.cloud.google.com/gemini-enterprise-agent-platform/build/runtime/quickstart-adk?authuser=2
# 1. Correct Official Runtime Import for Gemini Enterprise ADK
from google.adk.runtime import Runner 
from google.adk.sessions import VertexAiSessionService
# ==============================================================================

# Load environment variables
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

# Make the Google Cloud project available to ADK / Google client libraries.
os.environ.setdefault("GOOGLE_CLOUD_PROJECT", GCP_PROJECT_ID)

app = FastAPI(title="WhatsApp Gemini Agent Webhook")


# Initialize the ADK Runner with Google Cloud memory
cloud_memory = VertexAiSessionService(agent_engine_id=os.getenv("AGENT_ENGINE_ID"))
runner = Runner(agent=whatsapp_agent, session_service=cloud_memory)

# ==============================================================================

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
async def receive_message(request: Request):
    body = await request.json()

    try:
        entry = body.get("entry", [])[0]
        changes = entry.get("changes", [])[0]
        value = changes.get("value", {})
        messages = value.get("messages", [])
        
        if not messages:
            return {"status": "Not a message payload"}
            
        message = messages[0]
        
        # Data Extraction
        phone_number = message.get("from")
        message_text = message.get("text", {}).get("body")

        if not phone_number or not message_text:
            return {"status": "Missing text or phone number"}


        # ==============================================================================
        # Concept Source: https://adk.dev/run/resume-agents
        # 4. Correct Official State Management (The "Memory" Rule)
        # We use the ADK Runner, passing the phone number as 'user_id' to isolate state.
        
        # We must gather the async events to get the final message text
        final_response = ""
        async for event in runner.run_async(user_id=phone_number, session_id=phone_number, input=message_text):
            if event.output:
                final_response = event.output
        
        print(f"Isolated ADK Agent response for {phone_number}: {final_response}")
        
        # ==============================================================================
        # OFFICIAL SOURCE: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/send-messages
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


        return {"status": "success"}

    except Exception as e:
        print(f"Error parsing webhook: {e}")
        return {"status": "error"}
