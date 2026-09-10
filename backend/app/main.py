from __future__ import annotations

import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .routers import diagnostics, jobs, kits, live

app = FastAPI(title="Railway Braking Dashboard API")

# Vite's default dev port, plus any extra origins (e.g. the deployed
# frontend URL) supplied via ALLOWED_ORIGINS as a comma-separated list.
_allowed_origins = ["http://localhost:5173"] + [
    origin.strip()
    for origin in os.environ.get("ALLOWED_ORIGINS", "").split(",")
    if origin.strip()
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(jobs.router)
app.include_router(kits.router)
app.include_router(diagnostics.router)
app.include_router(live.router)


@app.get("/api/health")
def health():
    return {"status": "ok"}
