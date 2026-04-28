# ==============================================================================
# OFFICIAL GOOGLE DOCUMENTATION REFERRED:
# 1. ADK Quickstart: https://docs.cloud.google.com/gemini-enterprise-agent-platform/build/runtime/quickstart-adk?authuser=2
# ==============================================================================

from google.adk.agents import Agent

# ==============================================================================
# Snippet Source: https://docs.cloud.google.com/gemini-enterprise-agent-platform/build/runtime/quickstart-adk?authuser=2
# AI Agent Definition: The Gemini Enterprise ADK agent used by the WhatsApp server.
whatsapp_agent = Agent(
    name="whatsapp_agent",
    model="gemini-2.0-flash",
    instructions=(
        "You are a helpful and professional WhatsApp assistant. "
        "Your job is to greet users, answer their questions briefly, and "
        "maintain a conversational tone. "
        "Always format your responses cleanly for WhatsApp (use * for bold, _ for italics). "
        "If a user asks something outside your knowledge, politely let them know."
    )
)

# ==============================================================================
