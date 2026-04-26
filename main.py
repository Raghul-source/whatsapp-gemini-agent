# ==============================================================================
# OFFICIAL GOOGLE & META DOCUMENTATION REFERRED:
# 1. ADK Quickstart: https://docs.cloud.google.com/gemini-enterprise-agent-platform/build/runtime/quickstart-adk?authuser=2
# 2. Meta Webhooks: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/set-up-webhooks
# ==============================================================================

import os
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import PlainTextResponse
from dotenv import load_dotenv

# ==============================================================================
# Snippet Source: https://docs.cloud.google.com/gemini-enterprise-agent-platform/build/runtime/quickstart-adk?authuser=2
# 1. Correct Official Imports for Gemini Enterprise ADK
from google.adk.agents import Agent
from vertexai import agent_engines
# ==============================================================================

# Load environment variables
load_dotenv()
META_VERIFY_TOKEN = os.getenv("META_VERIFY_TOKEN")

app = FastAPI(title="WhatsApp Gemini Agent Webhook")

# ==============================================================================
# Snippet Source: https://docs.cloud.google.com/gemini-enterprise-agent-platform/build/runtime/quickstart-adk?authuser=2
# 2. Correct Official Agent Initialization
agent = Agent(
    name="whatsapp_agent",
    model="gemini-2.0-flash" 
)

# 3. Initialize the AdkApp Wrapper for Automatic Session Management
adk_app = agent_engines.AdkApp(agent=agent)
# ==============================================================================

@app.get("/webhook")
def verify_webhook(request: Request):
    """
    Verify Webhook: Handles Meta's initial webhook verification token.
    """
    mode = request.query_params.get("hub.mode")
    token = request.query_params.get("hub.verify_token")
    challenge = request.query_params.get("hub.challenge")

    if mode and token:
        if mode == "subscribe" and token == META_VERIFY_TOKEN:
            return PlainTextResponse(content=str(challenge))
        else:
            raise HTTPException(status_code=403, detail="Verification token mismatch")
    
    raise HTTPException(status_code=400, detail="Missing parameters")


@app.post("/webhook")
async def receive_message(request: Request):
    """
    Receive Messages & Data Extraction: Catches WhatsApp messages and isolates state per user.
    """
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
        # Concept Source: https://docs.cloud.google.com/gemini-enterprise-agent-platform/build/runtime/quickstart-adk?authuser=2
        # 4. Correct Official State Management (The "Memory" Rule)
        # Passing the phone number as 'user_id' isolates the state per user.
        response = await adk_app.async_query(
            user_id=phone_number,
            message=message_text
        )
        # ==============================================================================

        print(f"Isolated ADK Agent response for {phone_number}: {response}")

        return {"status": "success"}

    except Exception as e:
        print(f"Error parsing webhook: {e}")
        return {"status": "error"}
