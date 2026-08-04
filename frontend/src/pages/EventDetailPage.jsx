import { useParams, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { getEvent } from '../api/client'
import EventMiniMap from '../components/EventMiniMap.jsx'

export default function EventDetailPage() {
  const { kitId, eventId } = useParams()

  const { data: event, isLoading, isError, error } = useQuery({
    queryKey: ['event', kitId, eventId],
    queryFn: () => getEvent(kitId, Number(eventId)),
  })

  if (isLoading) return <p className="text-slate-500 dark:text-slate-400">Loading event...</p>
  if (isError) return <p className="text-rose-600 dark:text-rose-400">{String(error)}</p>

  return (
    <div>
      <p className="mb-2">
        <Link to={`/kits/${kitId}`} className="text-sky-600 hover:underline dark:text-sky-400">
          ← back to {kitId}
        </Link>
      </p>
      <div className="flex flex-wrap items-start justify-between gap-4">
        <h1 className="text-2xl font-semibold tracking-tight">
          Event #{event.PhaseIdx ?? event.event_id} — {kitId}
        </h1>
        <EventMiniMap event={event} />
      </div>
      <div className="mt-6 overflow-x-auto rounded-lg border border-slate-200 dark:border-slate-800">
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
