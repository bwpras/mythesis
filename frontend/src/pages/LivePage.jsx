import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { startLiveWatcher, stopLiveWatcher, getLiveStatus, getLiveEvents, clearLiveEvents } from '../api/client'
import LiveCyclePlotCard from '../components/LiveCyclePlotCard.jsx'
import PredictionBadge from '../components/PredictionBadge.jsx'

const POLL_MS = 2000
// A cycle is exported as one row per candidate BC/WV pairing (up to 4, all
// sharing the same Start_brake_time_pipe) -- a plot is per CYCLE, not per
// row, so this caps how many distinct cycles get their own chart fetched
// and rendered at once (Plotly isn't free to mount repeatedly).
const MAX_PLOTTED_CYCLES = 5

export default function LivePage() {
  const [kitId, setKitId] = useState('Dati10')
  const [watchDir, setWatchDir] = useState('')
  const queryClient = useQueryClient()

  const { data: status, isError: statusError, error: statusErrorObj } = useQuery({
    queryKey: ['live-status', kitId],
    queryFn: () => getLiveStatus(kitId),
    enabled: Boolean(kitId),
    retry: false,
    refetchInterval: (query) => (query.state.data?.is_running ? POLL_MS : false),
    // Same reasoning as JobsPage's poll: a watcher is exactly the kind of
    // thing a user starts and then tabs away from -- without this, polling
    // silently pauses on visibilitychange and the status panel freezes.
    refetchIntervalInBackground: true,
  })

  const isRunning = Boolean(status?.is_running)

  const { data: events } = useQuery({
    queryKey: ['live-events', kitId],
    queryFn: () => getLiveEvents(kitId, { limit: 50 }),
    enabled: Boolean(kitId),
    retry: false,
    refetchInterval: isRunning ? POLL_MS : false,
    refetchIntervalInBackground: true,
  })

  const startMutation = useMutation({
    mutationFn: () => startLiveWatcher(kitId, watchDir),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['live-status', kitId] })
      queryClient.invalidateQueries({ queryKey: ['live-events', kitId] })
    },
  })

  const stopMutation = useMutation({
    mutationFn: () => stopLiveWatcher(kitId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['live-status', kitId] })
    },
  })

  const clearMutation = useMutation({
    mutationFn: () => clearLiveEvents(kitId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['live-events', kitId] })
    },
  })

  // events is already sorted desc by Start_brake_time_pipe (see
  // routers/live.py's recent_events()) -- one row per candidate BC/WV
  // pairing (up to 4) means duplicates for the same cycle land adjacently.
  // Which pairing is "the real one" for a phase isn't tagged anywhere, so
  // picking an arbitrary row as the cycle's representative can surface a
  // candidate that never got scored even when a sibling row did -- prefer
  // whichever of the 4 has a real prediction, so the badge shown reflects
  // the best information available for that cycle, not just the first row.
  const recentCycles = useMemo(() => {
    if (!events) return []
    const isScored = (row) => row.predicted_leakage !== null && row.predicted_leakage !== undefined
    const byTime = new Map()
    for (const ev of events) {
      const key = ev.Start_brake_time_pipe
      const existing = byTime.get(key)
      if (!existing || (isScored(ev) && !isScored(existing))) {
        byTime.set(key, ev)
      }
    }
    return Array.from(byTime.values()).slice(0, MAX_PLOTTED_CYCLES)
  }, [events])

  const inputClass =
    'rounded-md border border-slate-300 px-3 py-1.5 text-sm dark:border-slate-700 dark:bg-slate-900'

  return (
    <div>
      <h1 className="text-2xl font-semibold tracking-tight">Live prediction</h1>
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">
        Watches a folder for new <code>_p.bin</code>/<code>_pjm.bin</code> files and scores each completed
        braking cycle as soon as it closes — an in-progress cycle spanning multiple file arrivals stays
        buffered in memory until it does. Demo/replay only (see <code>replay_bin_files.py</code>); the
        target kit needs a locked pairing registry first (run it once via the Jobs page).
      </p>

      <div className="mt-6 flex flex-wrap items-end gap-4 rounded-lg border border-slate-200 p-4 dark:border-slate-800">
        <label className="flex flex-col gap-1 text-xs font-medium text-slate-500 dark:text-slate-400">
          Kit
          <input
            className={inputClass}
            value={kitId}
            onChange={(e) => setKitId(e.target.value)}
            disabled={isRunning}
          />
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-slate-500 dark:text-slate-400">
          Watch folder (server-side path)
          <input
            className={`${inputClass} w-96`}
            placeholder="e.g. C:\path\to\watch_dir"
            value={watchDir}
            onChange={(e) => setWatchDir(e.target.value)}
            disabled={isRunning}
          />
        </label>
        {!isRunning ? (
          <button
            disabled={startMutation.isPending || !kitId || !watchDir}
            onClick={() => startMutation.mutate()}
            className="rounded-md bg-sky-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-sky-700 disabled:opacity-50"
          >
            {startMutation.isPending ? 'Starting...' : 'Start watcher'}
          </button>
        ) : (
          <button
            disabled={stopMutation.isPending}
            onClick={() => stopMutation.mutate()}
            className="rounded-md bg-rose-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-rose-700 disabled:opacity-50"
          >
            {stopMutation.isPending ? 'Stopping...' : 'Stop watcher'}
          </button>
        )}
      </div>

      {startMutation.isError && (
        <p className="mt-3 text-rose-600 dark:text-rose-400">{String(startMutation.error?.response?.data?.detail ?? startMutation.error)}</p>
      )}

      <h2 className="mt-8 text-lg font-semibold tracking-tight">Status</h2>
      {statusError && String(statusErrorObj).includes('404') && (
        <p className="mt-2 text-slate-500 dark:text-slate-400">No watcher running for {kitId} yet.</p>
      )}
      {status && (
        <div className="mt-3 grid grid-cols-2 gap-4 rounded-lg border border-slate-200 p-4 text-sm dark:border-slate-800 sm:grid-cols-4">
          <div>
            <div className="text-xs uppercase tracking-wide text-slate-400">State</div>
            <div className="mt-1 font-medium">
              {status.is_running ? (
                <span className="inline-flex items-center rounded-full bg-sky-100 px-2 py-0.5 text-xs font-medium text-sky-800 dark:bg-sky-500/20 dark:text-sky-300">
                  watching
                </span>
              ) : (
                <span className="inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700 dark:bg-slate-800 dark:text-slate-300">
                  stopped
                </span>
              )}
            </div>
          </div>
          <div>
            <div className="text-xs uppercase tracking-wide text-slate-400">Cycle in progress</div>
            <div className="mt-1 font-medium">{status.cycle_in_progress ? 'yes — buffering' : 'no'}</div>
          </div>
          <div>
            <div className="text-xs uppercase tracking-wide text-slate-400">Files processed</div>
            <div className="mt-1 font-medium">{status.files_processed}</div>
          </div>
          <div>
            <div className="text-xs uppercase tracking-wide text-slate-400">Cycles completed</div>
            <div className="mt-1 font-medium">{status.phases_completed}</div>
          </div>
          {status.last_error && (
            <div className="col-span-full">
              <div className="text-xs uppercase tracking-wide text-amber-500">Last warning</div>
              <div className="mt-1 whitespace-pre-wrap font-mono text-xs text-amber-600 dark:text-amber-400">
                {status.last_error}
              </div>
            </div>
          )}
        </div>
      )}

      <div className="mt-8 flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-lg font-semibold tracking-tight">Recent cycles</h2>
        <button
          disabled={isRunning || clearMutation.isPending || !events || events.length === 0}
          title={isRunning ? 'Stop the watcher first' : undefined}
          onClick={() => {
            if (window.confirm(`Delete all stored live events and pressure history for ${kitId}? This cannot be undone.`)) {
              clearMutation.mutate()
            }
          }}
          className="rounded-md border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-600 hover:bg-slate-100 disabled:opacity-40 dark:border-slate-700 dark:text-slate-300 dark:hover:bg-slate-800"
        >
          {clearMutation.isPending ? 'Clearing...' : 'Clear events'}
        </button>
      </div>
      {clearMutation.isError && (
        <p className="mt-2 text-rose-600 dark:text-rose-400">
          {String(clearMutation.error?.response?.data?.detail ?? clearMutation.error)}
        </p>
      )}
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">
        Pressure history and GPS fix for the {MAX_PLOTTED_CYCLES} most recently completed cycles.
      </p>
      {recentCycles.length === 0 && (
        <p className="mt-2 text-slate-500 dark:text-slate-400">No completed cycles yet.</p>
      )}
      <div className="mt-3 space-y-4">
        {recentCycles.map((ev) => (
          <LiveCyclePlotCard key={ev.Start_brake_time_pipe} kitId={kitId} event={ev} />
        ))}
      </div>

      <h2 className="mt-8 text-lg font-semibold tracking-tight">Live events</h2>
      {(!events || events.length === 0) && (
        <p className="mt-2 text-slate-500 dark:text-slate-400">No completed cycles yet.</p>
      )}
      {events && events.length > 0 && (
        <div className="mt-3 overflow-x-auto rounded-lg border border-slate-200 dark:border-slate-800">
          <table className="w-full text-left text-sm">
            <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500 dark:bg-slate-900 dark:text-slate-400">
              <tr>
                <th className="px-4 py-3 font-medium">Start (brake, pipe)</th>
                <th className="px-4 py-3 font-medium">MBP / BC / WV</th>
                <th className="px-4 py-3 font-medium">Max P (pipe/cyl)</th>
                <th className="px-4 py-3 font-medium">Predicted</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-200 dark:divide-slate-800">
              {events.map((ev) => (
                <tr key={ev.event_id} className="bg-white hover:bg-slate-50 dark:bg-slate-950 dark:hover:bg-slate-900">
                  <td className="px-4 py-3">
                    <Link
                      to={`/live/${kitId}/events/${ev.event_id}`}
                      className="text-sky-600 hover:underline dark:text-sky-400"
                    >
                      {ev.Start_brake_time_pipe}
                    </Link>
                  </td>
                  <td className="px-4 py-3 font-mono text-xs">{ev.MBP_ID} / {ev.BC_ID} / {ev.WV_ID}</td>
                  <td className="px-4 py-3">
                    {ev.Max_pressure_pipe?.toFixed?.(2)} / {ev.Max_pressure_cyl?.toFixed?.(2)}
                  </td>
                  <td className="px-4 py-3">
                    <PredictionBadge predicted={ev.predicted_leakage} inScope={ev.prediction_in_scope} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
