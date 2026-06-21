# FastAPI app — serves Aria, the topic-scoped enterprise RAG chatbot.
#
# Authentication is handled by Azure App Service Easy Auth (Entra ID): every request reaching
# this app is already authenticated at the platform level, and the user's app roles arrive in the
# signed X-MS-CLIENT-PRINCIPAL header. All authorization logic lives in access.py (unit-tested).
#
# Topics are department-scoped chatbots over one shared infrastructure stack. The server derives a
# two-dimensional search filter (topic eq X and access_level in ...) purely from the user's roles —
# a role for topic A can never retrieve topic B content, in chat or in the document manager.
#
# Routes:
#   GET  /                     landing page — cards for the topics the user can access
#   GET  /t/{topic}            topic-scoped chat UI
#   GET  /admin                document manager (Content.Admin holders only)
#   POST /api/chat             topic-scoped streaming RAG answer (SSE)
#   GET  /api/topics           topics the current user may access
#   GET  /api/topics/{t}/overview  AI suggested questions + readable doc descriptions (access-scoped)
#   GET  /api/admin/topics     topics the current user may manage
#   GET  /api/admin/documents  list documents in a topic
#   POST /api/admin/documents  upload a document
#   DELETE /api/admin/documents soft-delete a document (IsDeleted metadata)
#   POST /api/admin/reindex    trigger the AI Search indexer

import json
import logging
import os
import posixpath
import re
import time

from azure.monitor.opentelemetry import configure_azure_monitor
from azure.core.exceptions import HttpResponseError, ResourceNotFoundError
from azure.core.credentials import AzureKeyCredential
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents import SearchClient
from azure.search.documents.indexes import SearchIndexerClient
from azure.search.documents.models import VectorizedQuery
from azure.storage.blob import BlobServiceClient, ContentSettings
from fastapi import FastAPI, HTTPException, Request, UploadFile, Form, File
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from openai import AzureOpenAI
from pydantic import BaseModel, field_validator

import access

if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    configure_azure_monitor()

logger = logging.getLogger(__name__)

OPENAI_ENDPOINT = os.environ["AZURE_OPENAI_ENDPOINT"]
SEARCH_ENDPOINT = os.environ["AZURE_SEARCH_ENDPOINT"]
CHAT_DEPLOYMENT = os.environ.get("AZURE_OPENAI_CHAT_DEPLOYMENT", "gpt-4o")
EMBEDDING_DEPLOYMENT = os.environ.get("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-3-small")
SEARCH_INDEX = os.environ.get("AZURE_SEARCH_INDEX", "rag-index")
SEARCH_INDEXER = os.environ.get("AZURE_SEARCH_INDEXER", "rag-indexer")
SEMANTIC_ENABLED = os.environ.get("AZURE_SEARCH_SEMANTIC_ENABLED", "false").lower() == "true"
COMPANY_NAME = os.environ.get("COMPANY_NAME", "Contoso")
STORAGE_ACCOUNT = os.environ.get("AZURE_STORAGE_ACCOUNT", "")
DOCUMENTS_CONTAINER = os.environ.get("DOCUMENTS_CONTAINER", "documents")
SEARCH_API_KEY = os.environ.get("AZURE_SEARCH_API_KEY", "")

TOPICS = access.parse_topics(os.environ.get("TOPICS", ""))
TIERS = access.parse_tiers(os.environ.get("TIERS", ""))
PUBLIC_TIER_MODE = os.environ.get("PUBLIC_TIER_MODE", "all_users")

STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")

# Managed Identity credential — no API keys. RBAC assigned in Terraform:
#   Cognitive Services OpenAI User (OpenAI), Search Index Data Reader + Search Service Contributor
#   (AI Search), Storage Blob Data Contributor (Storage).
credential = DefaultAzureCredential()
token_provider = get_bearer_token_provider(credential, "https://cognitiveservices.azure.com/.default")

openai_client = AzureOpenAI(
    azure_endpoint=OPENAI_ENDPOINT,
    azure_ad_token_provider=token_provider,
    api_version="2024-10-21",
)

# Free-tier Search has no managed identity, so it authenticates with an admin key; the secure
# baseline uses RBAC via the managed identity. Both Search clients share whichever applies.
search_credential = AzureKeyCredential(SEARCH_API_KEY) if SEARCH_API_KEY else credential

search_client = SearchClient(
    endpoint=SEARCH_ENDPOINT,
    index_name=SEARCH_INDEX,
    credential=search_credential,
)

indexer_client = SearchIndexerClient(endpoint=SEARCH_ENDPOINT, credential=search_credential)

# Blob access is only needed by the document manager; skip the client when storage isn't configured.
blob_container = None
if STORAGE_ACCOUNT:
    blob_service = BlobServiceClient(
        account_url=f"https://{STORAGE_ACCOUNT}.blob.core.windows.net",
        credential=credential,
    )
    blob_container = blob_service.get_container_client(DOCUMENTS_CONTAINER)

CONTENT_TYPES = {"txt": "text/plain", "md": "text/markdown", "csv": "text/csv", "pdf": "application/pdf"}

app = FastAPI()


# ── Models ──────────────────────────────────────────────────────────────────

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
    topic: str
    message: str
    history: list[Message] = []


# ── Auth helpers ────────────────────────────────────────────────────────────

def require_roles(request: Request) -> set[str]:
    # Fail closed: if Easy Auth is not in the request path the principal header is absent,
    # so we refuse rather than default to public access.
    principal = request.headers.get("X-MS-CLIENT-PRINCIPAL", "")
    if not principal:
        raise HTTPException(status_code=401, detail="Authentication required")
    return access.get_user_roles(principal)


# ── RAG pipeline ────────────────────────────────────────────────────────────

def get_embedding(text: str) -> list[float]:
    response = openai_client.embeddings.create(model=EMBEDDING_DEPLOYMENT, input=text)
    return response.data[0].embedding


def search_documents(query: str, embedding: list[float], access_filter: str) -> list[dict]:
    # Hybrid search: vector + keyword (BM25) + optional semantic rerank, scoped by access_filter.
    vector_query = VectorizedQuery(vector=embedding, k_nearest_neighbors=5, fields="embedding")
    kwargs: dict = {
        "search_text": query,
        "vector_queries": [vector_query],
        "filter": access_filter,
        "select": ["content", "file_name"],
        "top": 5,
    }
    if SEMANTIC_ENABLED:
        kwargs["query_type"] = "semantic"
        kwargs["semantic_configuration_name"] = "rag-semantic-config"

    results = search_client.search(**kwargs)
    return [{"content": r["content"], "file": r["file_name"]} for r in results]


def build_context(chunks: list[dict]) -> str:
    return "\n\n---\n\n".join(f"[{chunk['file']}]\n{chunk['content']}" for chunk in chunks)


def generate_answer(context: str, message: str, history: list[Message], topic_display: str) -> str:
    # NON-STREAMING by design. Azure App Service Easy Auth proxies every response and cannot
    # reliably relay a long-lived text/event-stream body — it cuts the stream mid-answer
    # ("Error while copying content to a stream" in the Easy Auth middleware). Returning the full
    # answer in a single JSON response is delivered intact behind Easy Auth.
    system_prompt = (
        f"You are Aria, an enterprise assistant for the {topic_display} topic at {COMPANY_NAME}. "
        "Answer the user's question using ONLY the document excerpts below. "
        "Do not use any knowledge from your training data. "
        "If the answer is not contained in the excerpts, respond with exactly: "
        "\"I couldn't find that in the available documents.\"\n\n"
        f"Document excerpts:\n{context}"
    )
    messages = [{"role": "system", "content": system_prompt}]
    for turn in history[-10:]:
        messages.append({"role": turn.role, "content": turn.content})
    messages.append({"role": "user", "content": message})

    resp = openai_client.chat.completions.create(
        model=CHAT_DEPLOYMENT, messages=messages, temperature=0,
    )
    return resp.choices[0].message.content or ""


# ── Topic overview (suggested questions + readable document descriptions) ─────
#
# Onboarding aid for the chat page: a short list of questions the documents can answer, plus a
# plain-language description of each source document — so users learn what the assistant is for.
# Generated from the SAME access-filtered content the chat uses, so it never reveals a document
# (or its contents) the user isn't cleared for. Cached per (topic, access-scope) to bound cost.

OVERVIEW_TTL_SECONDS = 3600
OVERVIEW_MAX_FILES = 12
_overview_cache: dict[tuple, tuple[float, dict]] = {}


def _friendly_title(file_name: str) -> str:
    stem = file_name.rsplit(".", 1)[0]
    return re.sub(r"[-_]+", " ", stem).strip().title() or file_name


def gather_topic_documents(access_filter: str) -> list[dict]:
    # Sample accessible chunks and group them by source file. access_filter is the security boundary,
    # so this only ever sees documents the caller may read.
    results = search_client.search(
        search_text="*",
        filter=access_filter,
        select=["file_name", "content"],
        top=60,
    )
    by_file: dict[str, list[str]] = {}
    for r in results:
        name = r.get("file_name") or ""
        if not name:
            continue
        excerpts = by_file.setdefault(name, [])
        if len(excerpts) < 3:
            excerpts.append((r.get("content") or "")[:800])
    return [
        {"file_name": name, "excerpt": "\n".join(parts)[:1600]}
        for name, parts in list(by_file.items())[:OVERVIEW_MAX_FILES]
    ]


def generate_topic_overview(topic_display: str, docs: list[dict]) -> dict:
    if not docs:
        return {"questions": [], "documents": []}

    catalogue = "\n\n".join(f"FILE: {d['file_name']}\n{d['excerpt']}" for d in docs)
    system = (
        f"You help employees understand a {topic_display} assistant at {COMPANY_NAME}. "
        "Using ONLY the document excerpts provided, return a JSON object with two keys: "
        '"questions" — an array of 4 short, natural questions an employee could ask that these '
        'documents can answer; and "documents" — an array where each item has "file_name" (exactly '
        'as given), "title" (a short human-friendly title), and "description" (one plain-language '
        "sentence describing what the document covers). Describe only the files provided; invent nothing."
    )
    resp = openai_client.chat.completions.create(
        model=CHAT_DEPLOYMENT,
        messages=[{"role": "system", "content": system}, {"role": "user", "content": catalogue}],
        temperature=0,
        response_format={"type": "json_object"},
    )
    data = json.loads(resp.choices[0].message.content)

    questions = [q for q in data.get("questions", []) if isinstance(q, str) and q.strip()][:6]
    valid_names = {d["file_name"] for d in docs}
    documents = []
    for item in data.get("documents", []):
        name = item.get("file_name") if isinstance(item, dict) else None
        if name in valid_names:
            documents.append({
                "file_name": name,
                "title": (item.get("title") or _friendly_title(name)).strip(),
                "description": (item.get("description") or "").strip(),
            })
    return {"questions": questions, "documents": documents}


# ── Page routes ─────────────────────────────────────────────────────────────

def _serve(filename: str) -> HTMLResponse:
    with open(os.path.join(STATIC_DIR, filename), encoding="utf-8") as f:
        return HTMLResponse(f.read())


@app.get("/", response_class=HTMLResponse)
async def landing():
    return _serve("landing.html")


@app.get("/t/{topic}", response_class=HTMLResponse)
async def chat_page(topic: str):
    # Unknown topics 404; per-user access is enforced on the data APIs, not by serving the shell.
    if topic not in TOPICS:
        raise HTTPException(status_code=404, detail="Unknown topic")
    return _serve("chat.html")


@app.get("/admin", response_class=HTMLResponse)
async def admin_page():
    return _serve("admin.html")


# ── Data APIs ───────────────────────────────────────────────────────────────

@app.get("/api/config")
async def config():
    return {"company_name": COMPANY_NAME, "public_tier_mode": PUBLIC_TIER_MODE}


@app.get("/api/topics")
async def list_topics(request: Request):
    roles = require_roles(request)
    topics = access.accessible_topics(roles, TOPICS, TIERS, PUBLIC_TIER_MODE)
    return {
        "company_name": COMPANY_NAME,
        "topics": [{"slug": s, "display": d} for s, d in topics.items()],
        "can_admin": bool(access.admin_topics(roles, TOPICS)),
    }


@app.get("/api/topics/{topic}/overview")
def topic_overview(topic: str, request: Request):
    roles = require_roles(request)
    if topic not in TOPICS:
        raise HTTPException(status_code=404, detail="Unknown topic")
    levels = access.allowed_levels(roles, topic, TIERS, PUBLIC_TIER_MODE)
    if not levels:
        raise HTTPException(status_code=403, detail="You don't have access to this topic")
    access_filter = access.build_search_filter(roles, topic, TIERS, PUBLIC_TIER_MODE)

    # Cache key includes the access scope so users with different clearance never share an overview.
    cache_key = (topic, tuple(levels))
    cached = _overview_cache.get(cache_key)
    if cached and time.time() - cached[0] < OVERVIEW_TTL_SECONDS:
        return cached[1]

    try:
        docs = gather_topic_documents(access_filter)
    except Exception:
        logger.exception("topic_overview: failed to gather documents")
        docs = []

    try:
        overview = generate_topic_overview(TOPICS[topic], docs)
    except Exception:
        logger.exception("topic_overview: generation failed")
        # Graceful fallback: still surface document titles, just without AI descriptions/questions.
        overview = {
            "questions": [],
            "documents": [
                {"file_name": d["file_name"], "title": _friendly_title(d["file_name"]), "description": ""}
                for d in docs
            ],
        }

    _overview_cache[cache_key] = (time.time(), overview)
    return overview


@app.post("/api/chat")
def chat(body: ChatRequest, request: Request):
    roles = require_roles(request)

    if body.topic not in TOPICS:
        raise HTTPException(status_code=404, detail="Unknown topic")
    access_filter = access.build_search_filter(roles, body.topic, TIERS, PUBLIC_TIER_MODE)
    if access_filter is None:
        raise HTTPException(status_code=403, detail="You don't have access to this topic")

    topic_display = TOPICS[body.topic]

    # Sync handler → runs in Starlette's threadpool (blocking embed/search/LLM off the event loop).
    # Returns the full answer in one JSON response (no SSE — see generate_answer for why).
    try:
        embedding = get_embedding(body.message)
        chunks = search_documents(body.message, embedding, access_filter)
        context = build_context(chunks)
        answer = generate_answer(context, body.message, body.history, topic_display)
        return {"content": answer}
    except HttpResponseError as e:
        return JSONResponse(
            status_code=502,
            content={"error": f"Search error: {e.error.code if e.error else str(e)}"},
        )
    except Exception:
        logger.exception("Unhandled error in /api/chat")
        return JSONResponse(
            status_code=500,
            content={"error": "An internal error occurred. Please try again."},
        )


# ── Admin / document manager ────────────────────────────────────────────────

_SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")


def _require_admin(request: Request, topic: str) -> set[str]:
    roles = require_roles(request)
    if topic not in TOPICS or not access.can_admin_topic(roles, topic):
        # Same response whether the topic is unknown or simply not yours — don't leak topic existence.
        raise HTTPException(status_code=403, detail="You can't manage this topic")
    if blob_container is None:
        raise HTTPException(status_code=503, detail="Document storage is not configured")
    return roles


@app.get("/api/admin/topics")
async def admin_topic_list(request: Request):
    roles = require_roles(request)
    topics = access.admin_topics(roles, TOPICS)
    return {
        "company_name": COMPANY_NAME,
        "topics": [{"slug": s, "display": d} for s, d in topics.items()],
        "tiers": TIERS,
    }


@app.get("/api/admin/documents")
def admin_list_documents(request: Request, topic: str):
    _require_admin(request, topic)
    docs: list[dict] = []
    for blob in blob_container.list_blobs(name_starts_with=f"{topic}/", include=["metadata"]):
        meta = blob.metadata or {}
        if str(meta.get("IsDeleted", "")).lower() == "true":
            continue
        parts = blob.name.split("/", 2)
        if len(parts) != 3:
            continue  # not a <topic>/<level>/<file> blob
        _, level, file_name = parts
        docs.append({
            "path": blob.name,
            "file_name": file_name,
            "access_level": meta.get("access_level", level),
            "size": blob.size,
            "last_modified": blob.last_modified.isoformat() if blob.last_modified else None,
        })
    docs.sort(key=lambda d: (d["access_level"], d["file_name"]))
    return {"topic": topic, "documents": docs}


@app.post("/api/admin/documents")
def admin_upload_document(
    request: Request,
    topic: str = Form(...),
    access_level: str = Form(...),
    file: UploadFile = File(...),
):
    _require_admin(request, topic)
    if access_level not in TIERS:
        raise HTTPException(status_code=400, detail="Invalid access level")

    file_name = _SAFE_NAME.sub("_", posixpath.basename(file.filename or "")).strip("._")
    if not file_name:
        raise HTTPException(status_code=400, detail="Invalid file name")

    # Path is built server-side from the validated topic + level, so an admin physically cannot
    # write outside their own topic.
    blob_name = f"{topic}/{access_level}/{file_name}"
    ext = file_name.rsplit(".", 1)[-1].lower() if "." in file_name else ""
    content_type = CONTENT_TYPES.get(ext, "application/octet-stream")

    data = file.file.read()
    blob_container.upload_blob(
        name=blob_name,
        data=data,
        overwrite=True,
        content_settings=ContentSettings(content_type=content_type),
        metadata={"topic": topic, "access_level": access_level},
    )
    return JSONResponse(status_code=201, content={"path": blob_name})


@app.delete("/api/admin/documents")
def admin_delete_document(request: Request, topic: str, path: str):
    _require_admin(request, topic)
    # Defence in depth: the blob must live under the caller's topic regardless of the path passed in.
    if not path.startswith(f"{topic}/") or len(path.split("/", 2)) != 3:
        raise HTTPException(status_code=400, detail="Invalid document path")

    blob = blob_container.get_blob_client(path)
    try:
        props = blob.get_blob_properties()
    except ResourceNotFoundError:
        raise HTTPException(status_code=404, detail="Document not found")

    # Soft delete: the indexer's SoftDeleteColumnDeletionDetectionPolicy drops chunks whose blob
    # carries IsDeleted=true on the next run. Preserve the existing topic/access_level metadata.
    meta = dict(props.metadata or {})
    meta["IsDeleted"] = "true"
    blob.set_blob_metadata(metadata=meta)
    return {"path": path, "deleted": True}


@app.post("/api/admin/reindex")
def admin_reindex(request: Request, topic: str = Form(...)):
    # Reindexing runs the single shared indexer over the whole container; topic is required only to
    # prove the caller administers at least one topic.
    _require_admin(request, topic)
    try:
        indexer_client.run_indexer(SEARCH_INDEXER)
    except HttpResponseError as e:
        # 409 = an indexer run is already in progress; treat as success (the changes will be picked up).
        if e.status_code != 409:
            logger.exception("Failed to run indexer")
            raise HTTPException(status_code=502, detail="Could not start reindexing")
    return {"reindexing": True}


@app.get("/branding")
async def branding():
    return {"company_name": COMPANY_NAME}


@app.get("/health")
async def health():
    return {"status": "ok"}
