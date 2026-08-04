from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .routers import diagnostics, jobs, kits, live

app = FastAPI(title="Railway Braking Dashboard API")

# Local dev only: Vite's default port. Tighten this before any real deployment.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
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
