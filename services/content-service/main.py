import json
import os
import time
from typing import Optional

import redis as redis_client
from fastapi import FastAPI, HTTPException, Query, Request, Response
from prometheus_client import Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST

app = FastAPI(title="content-service", version="1.0.0")

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "path", "status"],
)

REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["method", "path"],
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5],
)

SERVICE_INFO = Gauge(
    "service_info",
    "Service information",
    ["version", "service_name"],
)
SERVICE_INFO.labels(version="1.0.0", service_name="content-service").set(1)

CACHE_HITS = Counter("cache_hits_total", "Total Redis cache hits")
CACHE_MISSES = Counter("cache_misses_total", "Total Redis cache misses")

# ---------------------------------------------------------------------------
# Redis connection
# ---------------------------------------------------------------------------

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
CACHE_TTL = 300  # seconds

def get_redis():
    try:
        r = redis_client.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            decode_responses=True,
            socket_connect_timeout=2,
            socket_timeout=2,
            max_connections=50,
        )
        r.ping()
        return r
    except Exception:
        return None

redis_conn = get_redis()

# ---------------------------------------------------------------------------
# Mock content database (20 items)
# ---------------------------------------------------------------------------

MOCK_CONTENT = {
    f"c-{str(i).zfill(3)}": {
        "id": f"c-{str(i).zfill(3)}",
        "title": title,
        "genre": genre,
        "duration_minutes": duration,
        "rating": rating,
        "thumbnail_url": f"https://cdn.example.com/thumbnails/c-{str(i).zfill(3)}.jpg",
        "description": f"An exciting {genre.lower()} experience.",
        "release_year": 2020 + (i % 5),
    }
    for i, (title, genre, duration, rating) in enumerate([
        ("The Last Horizon", "Sci-Fi", 142, "PG-13"),
        ("Ocean's Depth", "Documentary", 98, "G"),
        ("Crimson Falls", "Thriller", 115, "R"),
        ("Laughing Matters", "Comedy", 88, "PG"),
        ("Iron Giants", "Action", 128, "PG-13"),
        ("Whispering Pines", "Drama", 105, "PG"),
        ("Cosmic Voyage", "Sci-Fi", 136, "PG-13"),
        ("Wild Kingdom", "Documentary", 75, "G"),
        ("Dark Descent", "Horror", 99, "R"),
        ("Summer Breeze", "Romance", 92, "PG"),
        ("Code Red", "Action", 120, "PG-13"),
        ("The Mirror", "Drama", 110, "R"),
        ("Stardust Dreams", "Sci-Fi", 145, "PG"),
        ("Into the Wild", "Documentary", 82, "PG"),
        ("Midnight Echo", "Thriller", 118, "R"),
        ("Happy Trails", "Comedy", 85, "G"),
        ("Steel Fist", "Action", 132, "PG-13"),
        ("Quiet Storm", "Drama", 97, "PG"),
        ("Nebula Rising", "Sci-Fi", 148, "PG-13"),
        ("The Journey Home", "Drama", 103, "PG"),
    ], start=1)
}

# ---------------------------------------------------------------------------
# Middleware
# ---------------------------------------------------------------------------

@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.time()
    response = await call_next(request)
    duration = time.time() - start

    path = request.url.path
    if path not in ("/metrics", "/health"):
        REQUEST_COUNT.labels(
            method=request.method,
            path=path,
            status=str(response.status_code),
        ).inc()
        REQUEST_DURATION.labels(
            method=request.method,
            path=path,
        ).observe(duration)

    return response

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    redis_status = "ok"
    try:
        r = redis_client.Redis(host=REDIS_HOST, port=REDIS_PORT, socket_connect_timeout=1)
        r.ping()
    except Exception:
        redis_status = "degraded"

    return {
        "status": "ok",
        "service": "content-service",
        "redis": redis_status,
    }

@app.get("/metrics")
async def metrics():
    data = generate_latest()
    return Response(content=data, media_type=CONTENT_TYPE_LATEST)

@app.get("/content/{content_id}")
async def get_content(content_id: str):
    global redis_conn

    # Try cache first
    cache_key = f"content:{content_id}"
    try:
        if redis_conn is None:
            redis_conn = get_redis()
        if redis_conn:
            cached = redis_conn.get(cache_key)
            if cached:
                CACHE_HITS.inc()
                return json.loads(cached)
    except Exception:
        redis_conn = None  # reset on error, will retry next request

    CACHE_MISSES.inc()

    content = MOCK_CONTENT.get(content_id)
    if not content:
        raise HTTPException(status_code=404, detail=f"Content {content_id} not found")

    # Populate cache
    try:
        if redis_conn is None:
            redis_conn = get_redis()
        if redis_conn:
            redis_conn.setex(cache_key, CACHE_TTL, json.dumps(content))
    except Exception:
        pass  # cache write failure is non-fatal

    return content

@app.get("/content")
async def list_content(
    page: int = Query(default=1, ge=1),
    limit: int = Query(default=10, ge=1, le=100),
):
    items = list(MOCK_CONTENT.values())
    total = len(items)
    start = (page - 1) * limit
    end = start + limit
    page_items = items[start:end]

    return {
        "items": page_items,
        "page": page,
        "limit": limit,
        "total": total,
        "pages": (total + limit - 1) // limit,
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8082)

