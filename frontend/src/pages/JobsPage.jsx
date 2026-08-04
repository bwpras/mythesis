import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { startIngestJob, getJob } from '../api/client'

const POLL_MS = 2000

const STATUS_BADGE = {
  running: 'bg-sky-100 text-sky-800 dark:bg-sky-500/20 dark:text-sky-300',
  queued: 'bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-300',
  done: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-500/20 dark:text-emerald-300',
  failed: 'bg-rose-100 text-rose-800 dark:bg-rose-500/20 dark:text-rose-300',
}

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

  if (isError) return <p className="text-rose-600 dark:text-rose-400">{String(error)}</p>
  if (!job) return null

  return (
    <div className="mb-3 rounded-lg border border-slate-200 p-4 dark:border-slate-800">
      <div className="flex items-center gap-3">
        <span className="font-semibold">{job.kind}</span>
        <span className="text-xs text-slate-400">{job.id}</span>
        <span className={`ml-auto inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_BADGE[job.status] || ''}`}>
          {job.status}
        </span>
      </div>
      {job.progress && <div className="mt-2 text-sm text-slate-500 dark:text-slate-400">{job.progress}</div>}
      {job.status === 'done' && (
        <pre className="mt-2 overflow-x-auto rounded-md bg-slate-100 p-3 text-xs dark:bg-slate-900">
          {JSON.stringify(job.result, null, 2)}
        </pre>
      )}
      {job.status === 'failed' && (
        <pre className="mt-2 overflow-x-auto rounded-md bg-rose-50 p-3 text-xs text-rose-700 dark:bg-rose-500/10 dark:text-rose-300">
          {job.error}
        </pre>
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

  const inputClass =
    'rounded-md border border-slate-300 px-3 py-1.5 text-sm dark:border-slate-700 dark:bg-slate-900'

  return (
    <div>
      <h1 className="text-2xl font-semibold tracking-tight">Pipeline jobs</h1>
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">
        Runs Stage 1 (ingestion) + Stage 2 (feature extraction) for a kit and date range.
      </p>

      <div className="mt-6 flex flex-wrap items-end gap-4 rounded-lg border border-slate-200 p-4 dark:border-slate-800">
        <label className="flex flex-col gap-1 text-xs font-medium text-slate-500 dark:text-slate-400">
          Kit
          <input className={inputClass} value={kitId} onChange={(e) => setKitId(e.target.value)} />
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-slate-500 dark:text-slate-400">
          Start date
          <input
            type="date"
            className={inputClass}
            value={startDate}
            onChange={(e) => setStartDate(e.target.value)}
          />
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-slate-500 dark:text-slate-400">
          End date (exclusive)
          <input
            type="date"
            className={inputClass}
            value={endDate}
            onChange={(e) => setEndDate(e.target.value)}
          />
        </label>
        <button
          disabled={mutation.isPending}
          onClick={() => mutation.mutate({ kitId, startDate, endDate })}
          className="rounded-md bg-sky-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-sky-700 disabled:opacity-50"
        >
          {mutation.isPending ? 'Starting...' : 'Run pipeline'}
        </button>
      </div>

      {mutation.isError && (
        <p className="mt-3 text-rose-600 dark:text-rose-400">{String(mutation.error)}</p>
      )}

      <h2 className="mt-8 text-lg font-semibold tracking-tight">Jobs</h2>
      {jobIds.length === 0 && <p className="mt-2 text-slate-500 dark:text-slate-400">No jobs started yet this session.</p>}
      <div className="mt-4">
        {jobIds.map((id) => (
          <JobRow key={id} jobId={id} />
        ))}
      </div>
    </div>
  )
}
