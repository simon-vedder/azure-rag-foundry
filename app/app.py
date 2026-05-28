# FastAPI app — serves the RAG chatbot backend.
#
# Authentication is handled by Azure App Service Easy Auth (Entra ID).
# All requests reaching this app have already been authenticated at the platform level.
# User identity and roles are available via the X-MS-CLIENT-PRINCIPAL header (base64 JSON).
#
# RAG pipeline per /chat request:
#   1. Decode user roles from Easy Auth header
#   2. Embed the user's question via Azure OpenAI (text-embedding-3-small)
#   3. Hybrid search in AI Search: vector + keyword + semantic ranking, filtered by access level
#   4. Assemble retrieved chunks into a context block
#   5. Stream the answer from Azure OpenAI (gpt-4o) grounded on that context

import base64
import json
import logging
import os

from azure.monitor.opentelemetry import configure_azure_monitor
from azure.core.exceptions import HttpResponseError
from azure.core.credentials import AzureKeyCredential
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from openai import AzureOpenAI
from pydantic import BaseModel, field_validator

if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    configure_azure_monitor()

logger = logging.getLogger(__name__)

OPENAI_ENDPOINT = os.environ["AZURE_OPENAI_ENDPOINT"]
SEARCH_ENDPOINT = os.environ["AZURE_SEARCH_ENDPOINT"]
CHAT_DEPLOYMENT = os.environ.get("AZURE_OPENAI_CHAT_DEPLOYMENT", "gpt-4o")
EMBEDDING_DEPLOYMENT = os.environ.get("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-3-small")
SEARCH_INDEX = os.environ.get("AZURE_SEARCH_INDEX", "rag-index")
SEMANTIC_ENABLED = os.environ.get("AZURE_SEARCH_SEMANTIC_ENABLED", "false").lower() == "true"
COMPANY_NAME = os.environ.get("COMPANY_NAME", "Contoso")
SEARCH_API_KEY = os.environ.get("AZURE_SEARCH_API_KEY", "")

# Managed Identity credential — no API keys needed.
# The App Service system-assigned identity has the following RBAC roles assigned in Terraform:
#   - Cognitive Services OpenAI User  (on Azure OpenAI)
#   - Search Index Data Reader        (on AI Search)
#   - Storage Blob Data Reader        (on Storage Account)
credential = DefaultAzureCredential()
token_provider = get_bearer_token_provider(credential, "https://cognitiveservices.azure.com/.default")

openai_client = AzureOpenAI(
    azure_endpoint=OPENAI_ENDPOINT,
    azure_ad_token_provider=token_provider,
    api_version="2024-10-21",
)

search_client = SearchClient(
    endpoint=SEARCH_ENDPOINT,
    index_name=SEARCH_INDEX,
    credential=AzureKeyCredential(SEARCH_API_KEY) if SEARCH_API_KEY else credential,
)

app = FastAPI()


class Message(BaseModel):
    role: str
    content: str

    @field_validator("role")
    @classmethod
    def role_must_be_valid(cls, v: str) -> str:
        if v not in ("user", "assistant"):
            raise ValueError("role must be 'user' or 'assistant'")
        return v


class ChatRequest(BaseModel):
    message: str
    history: list[Message] = []


def get_user_roles(principal_header: str) -> set[str]:
    # Easy Auth injects X-MS-CLIENT-PRINCIPAL as a base64-encoded JSON object.
    # It contains the user's Entra ID claims, including app roles assigned in the app registration.
    if not principal_header:
        return set()
    try:
        padded = principal_header + "=" * (-len(principal_header) % 4)
        decoded = json.loads(base64.b64decode(padded))
        role_typ = decoded.get(
            "role_typ",
            "http://schemas.microsoft.com/ws/2008/06/identity/claims/role",
        )
        claims = decoded.get("claims", [])
        return {c["val"] for c in claims if c.get("typ") in (role_typ, "roles")}
    except Exception:
        return set()


def build_access_filter(roles: set[str]) -> str:
    # Every user can see public documents. Internal.Read and Confidential.Read are
    # app roles assigned in Entra ID and propagated via the Easy Auth token.
    levels = ["'public'"]
    if "Internal.Read" in roles:
        levels.append("'internal'")
    if "Confidential.Read" in roles:
        levels.append("'confidential'")
    return " or ".join(f"access_level eq {level}" for level in levels)


def get_embedding(text: str) -> list[float]:
    # Converts the user's question into a 1536-dimensional vector so AI Search can find
    # semantically similar document chunks, not just exact keyword matches.
    response = openai_client.embeddings.create(
        model=EMBEDDING_DEPLOYMENT,
        input=text,
    )
    return response.data[0].embedding


def search_documents(query: str, embedding: list[float], access_filter: str) -> list[dict]:
    # Hybrid search combines three signals:
    #   - Vector search:   finds chunks semantically similar to the query embedding
    #   - Keyword search:  BM25 scoring for exact/partial term matches (search_text)
    #   - Semantic ranker: reranks results by meaning using a language model (when enabled)
    # The access_filter ensures users only see documents their roles permit.
    vector_query = VectorizedQuery(
        vector=embedding,
        k_nearest_neighbors=5,
        fields="embedding",
    )

    kwargs: dict = {
        "search_text": query,
        "vector_queries": [vector_query],
        "filter": access_filter,
        "select": ["content", "file_name", "page_number"],
        "top": 5,
    }

    if SEMANTIC_ENABLED:
        kwargs["query_type"] = "semantic"
        kwargs["semantic_configuration_name"] = "rag-semantic-config"

    results = search_client.search(**kwargs)
    return [
        {"content": r["content"], "file": r["file_name"], "page": r["page_number"]}
        for r in results
    ]


def build_context(chunks: list[dict]) -> str:
    # Top N retrieved chunks are concatenated and passed to the LLM as grounding context.
    # This is the core of RAG — the model answers based on retrieved document content,
    # not its training data.
    return "\n\n---\n\n".join(
        f"[{chunk['file']}, page {chunk['page']}]\n{chunk['content']}"
        for chunk in chunks
    )


def stream_response(context: str, message: str, history: list[Message]):
    # The system prompt instructs the model to answer only from the provided context
    # and to say so clearly if the context doesn't contain the answer.
    system_prompt = (
        "You are an enterprise assistant. Answer the user's question using ONLY the document excerpts below. "
        "Do not use any knowledge from your training data. "
        "If the answer is not contained in the excerpts, respond with exactly: "
        "\"I couldn't find that in the available documents.\"\n\n"
        f"Document excerpts:\n{context}"
    )

    messages = [{"role": "system", "content": system_prompt}]
    for turn in history[-10:]:
        messages.append({"role": turn.role, "content": turn.content})
    messages.append({"role": "user", "content": message})

    stream = openai_client.chat.completions.create(
        model=CHAT_DEPLOYMENT,
        messages=messages,
        temperature=0,
        stream=True,
    )

    for chunk in stream:
        if chunk.choices and chunk.choices[0].delta.content:
            yield chunk.choices[0].delta.content


@app.get("/", response_class=HTMLResponse)
async def root():
    with open(os.path.join(os.path.dirname(__file__), "static", "index.html")) as f:
        return f.read()


@app.post("/chat")
async def chat(body: ChatRequest, request: Request):
    # Step 1: Read user identity from Easy Auth header.
    # This header is injected and signed by the platform — it cannot be forged by callers.
    # If it is absent, Easy Auth is not in the request path (misconfiguration or local dev).
    # Fail closed rather than defaulting to public-only access.
    principal = request.headers.get("X-MS-CLIENT-PRINCIPAL", "")
    if not principal:
        raise HTTPException(status_code=401, detail="Authentication required")
    roles = get_user_roles(principal)
    access_filter = build_access_filter(roles)

    def generate():
        try:
            # Step 2: Embed the user's question.
            embedding = get_embedding(body.message)
            # Step 3: Retrieve relevant document chunks from AI Search.
            chunks = search_documents(body.message, embedding, access_filter)
            # Step 4: Build context from retrieved chunks.
            context = build_context(chunks)
            # Step 5: Stream the grounded answer from Azure OpenAI.
            for token in stream_response(context, body.message, body.history):
                yield f"data: {json.dumps({'content': token})}\n\n"
        except HttpResponseError as e:
            yield f"data: {json.dumps({'error': f'Search error: {e.error.code if e.error else str(e)}'})}\n\n"
        except Exception as e:
            logger.exception("Unhandled error in /chat")
            yield f"data: {json.dumps({'error': 'An internal error occurred. Please try again.'})}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.get("/branding")
async def branding():
    return {"company_name": COMPANY_NAME}


@app.get("/health")
async def health():
    return {"status": "ok"}
