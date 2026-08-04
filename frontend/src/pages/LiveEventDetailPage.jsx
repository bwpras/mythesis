import { useParams, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { getLiveEvent, getLiveEventTimeseries } from '../api/client'
import EventMiniMap from '../components/EventMiniMap.jsx'
import PressureTimeChart from '../components/PressureTimeChart.jsx'

export default function LiveEventDetailPage() {
  const { kitId, eventId } = useParams()

  const { data: event, isLoading, isError, error } = useQuery({
    queryKey: ['live-event', kitId, eventId],
    queryFn: () => getLiveEvent(kitId, Number(eventId)),
  })

  // Independent of the event query: a cycle can exist as a CSV row with no
  // stored time-series (e.g. the timeseries save failed and was only
  // logged as a watcher warning) -- 404 there is a normal, handled case,
  // not an error state for the whole page.
  const { data: series } = useQuery({
    queryKey: ['live-event-timeseries', kitId, eventId],
    queryFn: () => getLiveEventTimeseries(kitId, Number(eventId)),
    retry: false,
    enabled: Boolean(event),
    throwOnError: false,
  })

  if (isLoading) return <p className="text-slate-500 dark:text-slate-400">Loading event...</p>
  if (isError) return <p className="text-rose-600 dark:text-rose-400">{String(error)}</p>

  return (
    <div>
      <p className="mb-2">
        <Link to="/live" className="text-sky-600 hover:underline dark:text-sky-400">
          ← back to Live
        </Link>
      </p>
      <div className="flex flex-wrap items-start justify-between gap-4">
        <h1 className="text-2xl font-semibold tracking-tight">
          Live cycle #{event.PhaseIdx ?? event.event_id} — {kitId}
        </h1>
        <EventMiniMap event={event} />
      </div>

      <h2 className="mt-6 text-lg font-semibold tracking-tight">Pressure vs. time</h2>
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">
        MBP (pipe) alongside up to 4 BC (cylinder) sensors, from the moment the cycle was detected.
      </p>
      <div className="mt-3">
        <PressureTimeChart series={series} />
      </div>

      <h2 className="mt-8 text-lg font-semibold tracking-tight">All fields</h2>
      <div className="mt-3 overflow-x-auto rounded-lg border border-slate-200 dark:border-slate-800">
        <table className="w-full text-left text-sm">
          <tbody className="divide-y divide-slate-200 dark:divide-slate-800">
            {Object.entries(event).map(([key, value]) => (
              <tr key={key} className="bg-white dark:bg-slate-950">
                <td className="w-72 bg-slate-50 px-4 py-2 font-medium text-slate-600 dark:bg-slate-900 dark:text-slate-300">
                  {key}
                </td>
                <td className="px-4 py-2">
                  {value === null || value === undefined ? <span className="text-slate-400">—</span> : String(value)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
