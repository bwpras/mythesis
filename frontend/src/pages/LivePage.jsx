import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  startLiveWatcher, stopLiveWatcher, getLiveStatus, getLiveEvents, clearLiveEvents, getLiveKitsReadiness,
  startReplay, stopReplay, getReplayStatus,
} from '../api/client'
import LiveCyclePlotCard from '../components/LiveCyclePlotCard.jsx'
import PredictionBadge from '../components/PredictionBadge.jsx'

const POLL_MS = 2000
// A cycle is exported as one row per candidate BC/WV pairing (up to 4, all
// sharing the same Start_brake_time_pipe) -- a plot is per CYCLE, not per
// row, so this caps how many distinct cycles get their own chart fetched
// and rendered at once (Plotly isn't free to mount repeatedly).
const MAX_PLOTTED_CYCLES = 5

// Plain localStorage, not a generic hook -- this is the only place in the
// app that needs to survive a route change. React Router fully unmounts
// LivePage on navigation, so component state (useState alone) resets to
// its initial value every time you tab away and back; these two fields
// are exactly the ones a user re-selects most often mid-demo.
const STORAGE_KIT_ID = 'live.kitId'
const STORAGE_WATCH_DIR = 'live.watchDir'

export default function LivePage() {
  // Dati05, not the larger Dati10: it's the one kit the public deploy ships
  // raw .bin + a locked pairing for, so it's the only one that starts ready
  // (GET /api/live/kits). Landing on an unready kit makes the page look inert.
  const [kitId, setKitIdState] = useState(() => localStorage.getItem(STORAGE_KIT_ID) || 'Dati05')
  const [watchDir, setWatchDirState] = useState(() => localStorage.getItem(STORAGE_WATCH_DIR) || '')
  const [replaySpeed, setReplaySpeed] = useState(40)
  const [replayStartFrom, setReplayStartFrom] = useState('')
  const [replayLoop, setReplayLoop] = useState(false)
  const queryClient = useQueryClient()

  const setKitId = (id) => {
    setKitIdState(id)
    localStorage.setItem(STORAGE_KIT_ID, id)
  }
  const setWatchDir = (dir) => {
    setWatchDirState(dir)
    localStorage.setItem(STORAGE_WATCH_DIR, dir)
  }

  const { data: kitsReadiness } = useQuery({
    queryKey: ['live-kits-readiness'],
    queryFn: getLiveKitsReadiness,
  })
  const selectedReadiness = kitsReadiness?.find((k) => k.kit_id === kitId)

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

  const { data: replayStatus, isError: replayStatusError, error: replayStatusErrorObj } = useQuery({
    queryKey: ['live-replay-status', kitId],
    queryFn: () => getReplayStatus(kitId),
    enabled: Boolean(kitId),
    retry: false,
    refetchInterval: (query) => (query.state.data?.is_running ? POLL_MS : false),
    refetchIntervalInBackground: true,
  })

  const isReplaying = Boolean(replayStatus?.is_running)

  // "Play" is the one-click path: it also starts the watcher first if it
  // isn't running yet, so a cold demo needs exactly one button instead of
  // "start the watcher, then separately start the replay into the same
  // folder" -- the two steps this feature exists to collapse.
  const playMutation = useMutation({
    mutationFn: async () => {
      if (!isRunning) {
        await startLiveWatcher(kitId, watchDir)
      }
      return startReplay(kitId, {
        destDir: watchDir,
        speed: Number(replaySpeed) || 0,
        startFrom: replayStartFrom || undefined,
        loop: replayLoop,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['live-status', kitId] })
      queryClient.invalidateQueries({ queryKey: ['live-replay-status', kitId] })
      queryClient.invalidateQueries({ queryKey: ['live-events', kitId] })
    },
  })

  const stopReplayMutation = useMutation({
    mutationFn: () => stopReplay(kitId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['live-replay-status', kitId] })
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
          <select
            className={inputClass}
            value={kitId}
            onChange={(e) => setKitId(e.target.value)}
            disabled={isRunning}
          >
            {/* Keeps a persisted-but-no-longer-listed kit selectable rather than
                the browser silently falling back to whatever option renders first. */}
            {kitId && !kitsReadiness?.some((k) => k.kit_id === kitId) && (
              <option value={kitId}>{kitId}</option>
            )}
            {kitsReadiness?.map((k) => (
              <option key={k.kit_id} value={k.kit_id}>
                {k.kit_id}{k.ready ? '' : ' (needs bootstrap)'}
              </option>
            ))}
          </select>
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
            disabled={startMutation.isPending || !kitId || !watchDir || (selectedReadiness && !selectedReadiness.ready)}
            title={selectedReadiness && !selectedReadiness.ready ? selectedReadiness.reasons.join(' ') : undefined}
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

      {selectedReadiness && !selectedReadiness.ready && (
        <p className="mt-3 text-amber-600 dark:text-amber-400">
          ⚠ {selectedReadiness.reasons.join(' ')}
        </p>
      )}

      {startMutation.isError && (
        <p className="mt-3 text-rose-600 dark:text-rose-400">{String(startMutation.error?.response?.data?.detail ?? startMutation.error)}</p>
      )}

      <h2 className="mt-8 text-lg font-semibold tracking-tight">Simulate live data</h2>
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">
        Drip-feeds <code>data/raw/{kitId || '{kit}'}</code> into the watch folder above at sped-up
        timing, standing in for a real live gateway (see <code>replay_bin_files.py</code>). Play
        starts the watcher too if it isn't running yet.
      </p>
      <div className="mt-3 flex flex-wrap items-end gap-4 rounded-lg border border-slate-200 p-4 dark:border-slate-800">
        <label className="flex flex-col gap-1 text-xs font-medium text-slate-500 dark:text-slate-400">
          Speed (× real time)
          <input
            type="number"
            min="0"
            step="1"
            className={`${inputClass} w-28`}
            value={replaySpeed}
            onChange={(e) => setReplaySpeed(e.target.value)}
            disabled={isReplaying}
          />
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-slate-500 dark:text-slate-400">
          Start from (optional)
          <input
            type="datetime-local"
            className={inputClass}
            value={replayStartFrom}
            onChange={(e) => setReplayStartFrom(e.target.value)}
            disabled={isReplaying}
          />
        </label>
        <label className="flex items-center gap-2 pb-1.5 text-xs font-medium text-slate-500 dark:text-slate-400">
          <input
            type="checkbox"
            checked={replayLoop}
            onChange={(e) => setReplayLoop(e.target.checked)}
            disabled={isReplaying}
          />
          Loop
        </label>
        {!isReplaying ? (
          <button
            disabled={playMutation.isPending || !kitId || !watchDir || (selectedReadiness && !selectedReadiness.ready)}
            title={selectedReadiness && !selectedReadiness.ready ? selectedReadiness.reasons.join(' ') : undefined}
            onClick={() => playMutation.mutate()}
            className="rounded-md bg-emerald-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
          >
            {playMutation.isPending ? 'Starting...' : '▶ Play'}
          </button>
        ) : (
          <button
            disabled={stopReplayMutation.isPending}
            onClick={() => stopReplayMutation.mutate()}
            className="rounded-md bg-rose-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-rose-700 disabled:opacity-50"
          >
            {stopReplayMutation.isPending ? 'Stopping...' : '■ Stop'}
          </button>
        )}
      </div>
      {playMutation.isError && (
        <p className="mt-3 text-rose-600 dark:text-rose-400">
          {String(playMutation.error?.response?.data?.detail ?? playMutation.error)}
        </p>
      )}
      {replayStatus && (
        <div className="mt-3 grid grid-cols-2 gap-4 rounded-lg border border-slate-200 p-4 text-sm dark:border-slate-800 sm:grid-cols-4">
          <div>
            <div className="text-xs uppercase tracking-wide text-slate-400">State</div>
            <div className="mt-1 font-medium">
              {isReplaying ? (
                <span className="inline-flex items-center rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-800 dark:bg-emerald-500/20 dark:text-emerald-300">
                  replaying
                </span>
              ) : (
                <span className="inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700 dark:bg-slate-800 dark:text-slate-300">
                  {/* files_total starts at 0 until the first file copies, so an
                      immediate stop (0/0) must not read as "ran to completion". */}
                  {replayStatus.finished_at && replayStatus.files_total > 0
                    && replayStatus.files_copied >= replayStatus.files_total
                    && !replayStatus.loop
                    ? 'finished' : 'stopped'}
                </span>
              )}
            </div>
          </div>
          <div>
            <div className="text-xs uppercase tracking-wide text-slate-400">Files copied</div>
            <div className="mt-1 font-medium">{replayStatus.files_copied} / {replayStatus.files_total || '?'}</div>
          </div>
          <div className="col-span-2">
            <div className="text-xs uppercase tracking-wide text-slate-400">Current file</div>
            <div className="mt-1 truncate font-mono text-xs" title={replayStatus.current_file ?? ''}>
              {replayStatus.current_file ?? '—'}
            </div>
          </div>
          {replayStatus.last_error && (
            <div className="col-span-full">
              <div className="text-xs uppercase tracking-wide text-amber-500">Last error</div>
              <div className="mt-1 whitespace-pre-wrap font-mono text-xs text-amber-600 dark:text-amber-400">
                {replayStatus.last_error}
              </div>
            </div>
          )}
        </div>
      )}
      {replayStatusError && String(replayStatusErrorObj).includes('404') && (
        <p className="mt-2 text-slate-500 dark:text-slate-400">No replay run yet for {kitId}.</p>
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
