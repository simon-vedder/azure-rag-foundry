"""
Ingestion pipeline — run manually: python ingest.py

Required env vars (set from Terraform outputs or .env):
  AZURE_OPENAI_ENDPOINT
  AZURE_SEARCH_ENDPOINT
  AZURE_STORAGE_ACCOUNT

Optional:
  AZURE_SEARCH_INDEX   (default: rag-index)
  AZURE_OPENAI_EMBEDDING_DEPLOYMENT  (default: text-embedding-3-small)

The script uses DefaultAzureCredential — run `az login` locally.
Your user account needs:
  - Storage Blob Data Reader on the storage account
  - Search Index Data Contributor on the search service
  - Cognitive Services OpenAI User on the OpenAI account

Documents in the `documents` blob container are organized by access level:
  public/         → access_level = "public"
  internal/       → access_level = "internal"
  confidential/   → access_level = "confidential"

Supported file types: PDF, DOCX, TXT
"""

import io
import os
import re
import time

import tiktoken
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents import SearchClient
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    HnswAlgorithmConfiguration,
    SearchableField,
    SearchField,
    SearchFieldDataType,
    SearchIndex,
    SemanticConfiguration,
    SemanticField,
    SemanticPrioritizedFields,
    SemanticSearch,
    SimpleField,
    VectorSearch,
    VectorSearchProfile,
)
from azure.storage.blob import BlobServiceClient
from openai import AzureOpenAI

OPENAI_ENDPOINT = os.environ["AZURE_OPENAI_ENDPOINT"]
SEARCH_ENDPOINT = os.environ["AZURE_SEARCH_ENDPOINT"]
STORAGE_ACCOUNT = os.environ["AZURE_STORAGE_ACCOUNT"]
SEARCH_INDEX = os.environ.get("AZURE_SEARCH_INDEX", "rag-index")
EMBEDDING_DEPLOYMENT = os.environ.get("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-3-small")
CONTAINER = "documents"
CHUNK_TOKENS = 700
CHUNK_OVERLAP = 70
EMBEDDING_DIMS = 1536
BATCH_SIZE = 100

credential = DefaultAzureCredential()
token_provider = get_bearer_token_provider(credential, "https://cognitiveservices.azure.com/.default")

openai_client = AzureOpenAI(
    azure_endpoint=OPENAI_ENDPOINT,
    azure_ad_token_provider=token_provider,
    api_version="2024-10-21",
)

blob_service = BlobServiceClient(
    account_url=f"https://{STORAGE_ACCOUNT}.blob.core.windows.net",
    credential=credential,
)

index_client = SearchIndexClient(endpoint=SEARCH_ENDPOINT, credential=credential)
search_client = SearchClient(endpoint=SEARCH_ENDPOINT, index_name=SEARCH_INDEX, credential=credential)

encoding = tiktoken.get_encoding("cl100k_base")


def ensure_index():
    fields = [
        SimpleField(name="id", type=SearchFieldDataType.String, key=True, filterable=True),
        SearchableField(name="content", type=SearchFieldDataType.String),
        SearchField(
            name="embedding",
            type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
            searchable=True,
            vector_search_dimensions=EMBEDDING_DIMS,
            vector_search_profile_name="hnsw-profile",
        ),
        SimpleField(name="file_name", type=SearchFieldDataType.String, filterable=True, facetable=True),
        SimpleField(name="page_number", type=SearchFieldDataType.Int32, filterable=True),
        SimpleField(name="access_level", type=SearchFieldDataType.String, filterable=True, facetable=True),
    ]

    vector_search = VectorSearch(
        algorithms=[HnswAlgorithmConfiguration(name="hnsw")],
        profiles=[VectorSearchProfile(name="hnsw-profile", algorithm_configuration_name="hnsw")],
    )

    semantic_search = SemanticSearch(
        configurations=[
            SemanticConfiguration(
                name="rag-semantic-config",
                prioritized_fields=SemanticPrioritizedFields(
                    content_fields=[SemanticField(field_name="content")]
                ),
            )
        ]
    )

    index = SearchIndex(
        name=SEARCH_INDEX,
        fields=fields,
        vector_search=vector_search,
        semantic_search=semantic_search,
    )

    index_client.create_or_update_index(index)
    print(f"Index '{SEARCH_INDEX}' ready.")


def extract_text(blob_name: str, data: bytes) -> list[tuple[str, int]]:
    """Returns list of (text, page_number) tuples."""
    ext = blob_name.rsplit(".", 1)[-1].lower()

    if ext == "txt":
        return [(data.decode("utf-8", errors="replace"), 1)]

    if ext == "pdf":
        from pypdf import PdfReader
        reader = PdfReader(io.BytesIO(data))
        return [(page.extract_text() or "", i + 1) for i, page in enumerate(reader.pages)]

    if ext == "docx":
        from docx import Document
        doc = Document(io.BytesIO(data))
        text = "\n".join(p.text for p in doc.paragraphs)
        return [(text, 1)]

    return []


def chunk_text(text: str) -> list[str]:
    tokens = encoding.encode(text)
    chunks = []
    start = 0
    while start < len(tokens):
        end = min(start + CHUNK_TOKENS, len(tokens))
        chunk = encoding.decode(tokens[start:end])
        chunks.append(chunk)
        start += CHUNK_TOKENS - CHUNK_OVERLAP
    return chunks


def get_embeddings(texts: list[str]) -> list[list[float]]:
    response = openai_client.embeddings.create(model=EMBEDDING_DEPLOYMENT, input=texts)
    return [item.embedding for item in sorted(response.data, key=lambda x: x.index)]


def access_level_from_path(blob_name: str) -> str:
    prefix = blob_name.split("/")[0].lower()
    if prefix in ("internal", "confidential"):
        return prefix
    return "public"


def safe_id(blob_name: str, page: int, chunk: int) -> str:
    base = re.sub(r"[^a-zA-Z0-9_\-=]", "_", f"{blob_name}_p{page}_c{chunk}")
    return base[:512]


def ingest_blob(blob_name: str):
    print(f"  Processing: {blob_name}")
    container_client = blob_service.get_container_client(CONTAINER)
    data = container_client.download_blob(blob_name).readall()
    access_level = access_level_from_path(blob_name)
    pages = extract_text(blob_name, data)

    if not pages:
        print(f"  Skipped (unsupported type): {blob_name}")
        return 0

    documents = []
    for page_text, page_num in pages:
        if not page_text.strip():
            continue
        chunks = chunk_text(page_text)
        embeddings = get_embeddings(chunks)
        for i, (chunk, embedding) in enumerate(zip(chunks, embeddings)):
            documents.append({
                "id": safe_id(blob_name, page_num, i),
                "content": chunk,
                "embedding": embedding,
                "file_name": blob_name,
                "page_number": page_num,
                "access_level": access_level,
            })

    for i in range(0, len(documents), BATCH_SIZE):
        batch = documents[i : i + BATCH_SIZE]
        search_client.upload_documents(batch)
        time.sleep(0.5)  # avoid throttling

    print(f"  Indexed {len(documents)} chunks from {blob_name}")
    return len(documents)


def main():
    ensure_index()

    container_client = blob_service.get_container_client(CONTAINER)
    blobs = [b.name for b in container_client.list_blobs()]

    if not blobs:
        print("No blobs found in container. Upload documents to:")
        print(f"  https://{STORAGE_ACCOUNT}.blob.core.windows.net/{CONTAINER}/")
        print("  Use subfolders: public/, internal/, confidential/")
        return

    total = 0
    for blob_name in blobs:
        total += ingest_blob(blob_name)

    print(f"\nDone. Total chunks indexed: {total}")


if __name__ == "__main__":
    main()
