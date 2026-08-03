import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { startIngestJob, getJob } from '../api/client'

const POLL_MS = 2000

function JobRow({ jobId }) {
  const { data: job, isError, error } = useQuery({
    queryKey: ['job', jobId],
    queryFn: () => getJob(jobId),
    refetchInterval: (query) => {
      const status = query.state.data?.status
      return status === 'done' || status === 'failed' ? false : POLL_MS
    },
    // A long-running pipeline job is exactly the kind of thing a user
    // starts and then tabs away from -- without this, polling silently
    // pauses on visibilitychange (TanStack Query's default) and the UI
    // freezes on a stale "running" state until the tab regains focus.
    refetchIntervalInBackground: true,
  })

  if (isError) return <p style={{ color: 'crimson' }}>{String(error)}</p>
  if (!job) return null

  return (
    <div className="job-row">
      <div><strong>{job.kind}</strong> — {job.id}</div>
      <div>status: {job.status}</div>
      {job.progress && <div>progress: {job.progress}</div>}
      {job.status === 'done' && (
        <pre>{JSON.stringify(job.result, null, 2)}</pre>
      )}
      {job.status === 'failed' && (
        <pre style={{ color: 'crimson' }}>{job.error}</pre>
      )}
    </div>
  )
}

export default function JobsPage() {
  const [kitId, setKitId] = useState('Dati01')
  const [startDate, setStartDate] = useState('2025-05-07')
  const [endDate, setEndDate] = useState('2025-07-25')
  const [jobIds, setJobIds] = useState([])
  const queryClient = useQueryClient()

  const mutation = useMutation({
    mutationFn: startIngestJob,
    onSuccess: (job) => {
      setJobIds((prev) => [job.id, ...prev])
      queryClient.invalidateQueries({ queryKey: ['job', job.id] })
    },
  })

  return (
    <div>
      <h1>Pipeline jobs</h1>
      <p>Runs Stage 1 (ingestion) + Stage 2 (feature extraction) for a kit and date range.</p>

      <div className="job-form">
        <label>
          Kit
          <input value={kitId} onChange={(e) => setKitId(e.target.value)} />
        </label>
        <label>
          Start date
          <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} />
        </label>
        <label>
          End date (exclusive)
          <input type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} />
        </label>
        <button
          disabled={mutation.isPending}
          onClick={() => mutation.mutate({ kitId, startDate, endDate })}
        >
          {mutation.isPending ? 'Starting...' : 'Run pipeline'}
        </button>
      </div>

      {mutation.isError && (
        <p style={{ color: 'crimson' }}>{String(mutation.error)}</p>
      )}

      <h2>Jobs</h2>
      {jobIds.length === 0 && <p>No jobs started yet this session.</p>}
      {jobIds.map((id) => (
        <JobRow key={id} jobId={id} />
      ))}
    </div>
  )
}
