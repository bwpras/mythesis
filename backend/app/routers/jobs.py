from __future__ import annotations

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from ..services import jobs as jobs_service
from ..services.pipeline import run_ingest_and_extract

router = APIRouter(prefix="/api/jobs", tags=["jobs"])


class IngestRequest(BaseModel):
    kit_id: str
    start_date: str
    end_date: str
    fsamp: int = 40
    workers: int = 4


@router.post("/ingest")
def start_ingest_job(req: IngestRequest):
    job_fn = run_ingest_and_extract(
        kit_id=req.kit_id,
        start_date=req.start_date,
        end_date=req.end_date,
        fsamp=req.fsamp,
        workers=req.workers,
    )
    job = jobs_service.submit_job(kind="ingest_and_extract", fn=job_fn)
    return job.to_dict()


@router.get("")
def list_jobs():
    return [j.to_dict() for j in jobs_service.list_jobs()]


@router.get("/{job_id}")
def get_job(job_id: str):
    job = jobs_service.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")
    return job.to_dict()
