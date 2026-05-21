import base64
import json
import os

from azure.core.exceptions import HttpResponseError
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from openai import AzureOpenAI
from pydantic import BaseModel

OPENAI_ENDPOINT = os.environ["AZURE_OPENAI_ENDPOINT"]
SEARCH_ENDPOINT = os.environ["AZURE_SEARCH_ENDPOINT"]
CHAT_DEPLOYMENT = os.environ.get("AZURE_OPENAI_CHAT_DEPLOYMENT", "gpt-4o-mini")
EMBEDDING_DEPLOYMENT = os.environ.get("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-3-small")
SEARCH_INDEX = os.environ.get("AZURE_SEARCH_INDEX", "rag-index")
SEMANTIC_ENABLED = os.environ.get("AZURE_SEARCH_SEMANTIC_ENABLED", "false").lower() == "true"
COMPANY_NAME = os.environ.get("COMPANY_NAME", "Contoso")
LOGO_URL = os.environ.get("LOGO_URL", "")

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
    credential=credential,
)

app = FastAPI()


class Message(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    message: str
    history: list[Message] = []


def get_user_roles(principal_header: str) -> set[str]:
    if not principal_header:
        return set()
    try:
        # Pad base64 to avoid decode errors
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
    levels = ["'public'"]
    if "Internal.Read" in roles:
        levels.append("'internal'")
    if "Confidential.Read" in roles:
        levels.append("'confidential'")
    return " or ".join(f"access_level eq {level}" for level in levels)


def get_embedding(text: str) -> list[float]:
    response = openai_client.embeddings.create(
        model=EMBEDDING_DEPLOYMENT,
        input=text,
    )
    return response.data[0].embedding


def search_documents(query: str, embedding: list[float], access_filter: str) -> list[dict]:
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
    return "\n\n---\n\n".join(
        f"[{chunk['file']}, page {chunk['page']}]\n{chunk['content']}"
        for chunk in chunks
    )


def stream_response(context: str, message: str, history: list[Message]):
    system_prompt = (
        "You are a helpful enterprise assistant. Answer questions based on the provided context. "
        "If the context does not contain enough information, say so clearly.\n\n"
        f"Context:\n{context}"
    )

    messages = [{"role": "system", "content": system_prompt}]
    for turn in history[-10:]:
        messages.append({"role": turn.role, "content": turn.content})
    messages.append({"role": "user", "content": message})

    stream = openai_client.chat.completions.create(
        model=CHAT_DEPLOYMENT,
        messages=messages,
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
    principal = request.headers.get("X-MS-CLIENT-PRINCIPAL", "")
    roles = get_user_roles(principal)
    access_filter = build_access_filter(roles)

    def generate():
        try:
            embedding = get_embedding(body.message)
            chunks = search_documents(body.message, embedding, access_filter)
            context = build_context(chunks)
            for token in stream_response(context, body.message, body.history):
                yield f"data: {json.dumps({'content': token})}\n\n"
        except HttpResponseError as e:
            yield f"data: {json.dumps({'error': f'Search error: {e.error.code if e.error else str(e)}'})}\n\n"
        except Exception as e:
            yield f"data: {json.dumps({'error': str(e)})}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.get("/branding")
async def branding():
    return {"company_name": COMPANY_NAME, "logo_url": LOGO_URL}


@app.get("/health")
async def health():
    return {"status": "ok"}
