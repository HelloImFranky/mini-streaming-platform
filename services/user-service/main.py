import time
import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from prometheus_client import Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST

app = FastAPI(title="user-service", version="1.0.0")

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
SERVICE_INFO.labels(version="1.0.0", service_name="user-service").set(1)

# ---------------------------------------------------------------------------
# Mock database
# ---------------------------------------------------------------------------

MOCK_USERS: dict = {
    "u-001": {
        "id": "u-001",
        "name": "Alice Johnson",
        "email": "alice@example.com",
        "subscription_tier": "premium",
        "created_at": "2023-01-15T10:00:00Z",
    },
    "u-002": {
        "id": "u-002",
        "name": "Bob Smith",
        "email": "bob@example.com",
        "subscription_tier": "standard",
        "created_at": "2023-03-22T14:30:00Z",
    },
    "u-003": {
        "id": "u-003",
        "name": "Carol Williams",
        "email": "carol@example.com",
        "subscription_tier": "premium",
        "created_at": "2023-06-01T09:15:00Z",
    },
    "u-004": {
        "id": "u-004",
        "name": "Dave Martinez",
        "email": "dave@example.com",
        "subscription_tier": "basic",
        "created_at": "2023-08-10T17:45:00Z",
    },
    "u-005": {
        "id": "u-005",
        "name": "Eve Thompson",
        "email": "eve@example.com",
        "subscription_tier": "standard",
        "created_at": "2023-11-05T12:00:00Z",
    },
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
# Models
# ---------------------------------------------------------------------------

class CreateUserRequest(BaseModel):
    name: str
    email: str
    subscription_tier: Optional[str] = "basic"

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {"status": "ok", "service": "user-service"}

@app.get("/metrics")
async def metrics():
    data = generate_latest()
    return Response(content=data, media_type=CONTENT_TYPE_LATEST)

@app.get("/users/{user_id}")
async def get_user(user_id: str):
    user = MOCK_USERS.get(user_id)
    if not user:
        raise HTTPException(status_code=404, detail=f"User {user_id} not found")
    return user

@app.post("/users", status_code=201)
async def create_user(request: CreateUserRequest):
    new_id = f"u-{str(uuid.uuid4())[:8]}"
    user = {
        "id": new_id,
        "name": request.name,
        "email": request.email,
        "subscription_tier": request.subscription_tier,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    MOCK_USERS[new_id] = user
    return user

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8081)

