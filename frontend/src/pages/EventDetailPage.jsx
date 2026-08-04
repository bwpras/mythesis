import { useParams, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { MapContainer, TileLayer, Marker } from 'react-leaflet'
import 'leaflet/dist/leaflet.css'
import { getEvent } from '../api/client'
import { TILE_URL, TILE_ATTRIBUTION, dotIcon } from '../components/mapUtils'

function EventMiniMap({ event }) {
  const lat = event.GPS_Lat_last
  const lon = event.GPS_Long_last
  // Excludes near-(0,0) too, not just NaN: a GPS cold-start/no-fix
  // sentinel, not a real location -- matches data_store.valid_gps_fix()
  // on the backend (see that function's docstring for why).
  const hasFix =
    typeof lat === 'number' && typeof lon === 'number' &&
    !Number.isNaN(lat) && !Number.isNaN(lon) &&
    (Math.abs(lat) >= 0.5 || Math.abs(lon) >= 0.5)

  if (!hasFix) {
    return (
      <div className="flex h-48 w-64 flex-shrink-0 flex-col items-center justify-center rounded-lg border border-slate-200 bg-slate-50 dark:border-slate-800 dark:bg-slate-900">
        <span className="text-2xl">📡</span>
        <p className="mt-1 text-sm font-medium text-rose-600 dark:text-rose-400">GPS error</p>
        <p className="text-xs text-slate-400">No fix for this event</p>
      </div>
    )
  }

  return (
    <div className="h-48 w-64 flex-shrink-0 overflow-hidden rounded-lg border border-slate-200 dark:border-slate-800">
      <MapContainer center={[lat, lon]} zoom={12} style={{ height: '100%', width: '100%' }} zoomControl={false}>
        <TileLayer attribution={TILE_ATTRIBUTION} url={TILE_URL} />
        <Marker position={[lat, lon]} icon={dotIcon('neutral', 14, false)} />
      </MapContainer>
    </div>
  )
}

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
