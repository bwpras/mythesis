import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { getLiveEventTimeseries } from '../api/client'
import EventMiniMap from './EventMiniMap.jsx'
import PredictionBadge from './PredictionBadge.jsx'
import PressureTimeChart from './PressureTimeChart.jsx'

// One completed cycle's pressure-vs-time chart + GPS fix, shown inline on
// the Live page itself (see LivePage.jsx's "Recent cycles" section) --
// LiveEventDetailPage.jsx renders the same two pieces for the full-detail
// view, this is the lightweight card version for scanning several cycles
// at once without navigating away.
export default function LiveCyclePlotCard({ kitId, event }) {
  const { data: series, isLoading } = useQuery({
    queryKey: ['live-event-timeseries', kitId, event.event_id],
    queryFn: () => getLiveEventTimeseries(kitId, event.event_id),
    retry: false,
  })

  return (
    <div className="rounded-lg border border-slate-200 p-4 dark:border-slate-800">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2 text-sm">
          <span className="font-medium">{event.Start_brake_time_pipe}</span>
          <span className="font-mono text-xs text-slate-400">{event.MBP_ID}</span>
          <PredictionBadge predicted={event.predicted_leakage} inScope={event.prediction_in_scope} />
        </div>
        <Link
          to={`/live/${kitId}/events/${event.event_id}`}
          className="text-sm text-sky-600 hover:underline dark:text-sky-400"
        >
          full detail →
        </Link>
      </div>
      <div className="mt-3 flex flex-wrap gap-4">
        <div className="min-w-[280px] flex-1">
          {isLoading ? (
            <div className="flex h-72 items-center justify-center text-sm text-slate-400">Loading...</div>
          ) : (
            <PressureTimeChart series={series} />
          )}
        </div>
        <EventMiniMap event={event} />
      </div>
    </div>
  )
}
