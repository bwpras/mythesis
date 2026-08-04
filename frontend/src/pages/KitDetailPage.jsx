import { useState } from 'react'
import { useParams, Link, useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { MapContainer, TileLayer, Marker, Tooltip } from 'react-leaflet'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { listEvents, getKit, getKitLocations } from '../api/client'
import { TILE_URL, TILE_ATTRIBUTION, dotIcon } from '../components/mapUtils'

const PAGE_SIZE = 25

function KitMap({ kitId }) {
  const navigate = useNavigate()
  const { data: locations, isLoading } = useQuery({
    queryKey: ['locations', kitId],
    queryFn: () => getKitLocations(kitId),
  })

  if (isLoading) return null

  if (!locations || locations.length === 0) {
    return (
      <div className="mt-6 flex h-56 items-center justify-center rounded-lg border border-slate-200 bg-slate-50 dark:border-slate-800 dark:bg-slate-900">
        <p className="text-sm text-slate-400">No GPS fixes for any event in this kit — GPS error</p>
      </div>
    )
  }

  const points = locations.map((l) => [l.lat, l.lon])
  const bounds = points.length > 1 ? L.latLngBounds(points).pad(0.15) : null

  return (
    <div className="mt-6 h-72 overflow-hidden rounded-lg border border-slate-200 dark:border-slate-800">
      <MapContainer
        {...(bounds ? { bounds } : { center: points[0], zoom: 10 })}
        style={{ height: '100%', width: '100%' }}
      >
        <TileLayer attribution={TILE_ATTRIBUTION} url={TILE_URL} />
        {locations.map((l) => (
          <Marker
            key={l.event_id}
            position={[l.lat, l.lon]}
            icon={dotIcon('neutral', 10)}
            eventHandlers={{ click: () => navigate(`/kits/${kitId}/events/${l.event_id}`) }}
          >
            <Tooltip direction="top" offset={[0, -6]}>
              {l.time} — click for event detail
            </Tooltip>
          </Marker>
        ))}
      </MapContainer>
    </div>
  )
}

export default function KitDetailPage() {
  const { kitId } = useParams()
  const [page, setPage] = useState(0)

  const { data: summary } = useQuery({
    queryKey: ['kit', kitId],
    queryFn: () => getKit(kitId),
  })

  const { data, isLoading, isError, error } = useQuery({
    queryKey: ['events', kitId, page],
    queryFn: () => listEvents(kitId, { offset: page * PAGE_SIZE, limit: PAGE_SIZE }),
  })

  return (
    <div>
      <h1 className="text-2xl font-semibold tracking-tight">{kitId}</h1>
      {summary && (
        <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">
          {summary.event_count} events · {summary.non_standard_count} non-standard ·{' '}
          {summary.sensor_error_count} with sensor errors ·{' '}
          <Link to={`/kits/${kitId}/model`} className="text-sky-600 hover:underline dark:text-sky-400">
            model info
          </Link>
        </p>
      )}

      <KitMap kitId={kitId} />

      {isLoading && <p className="mt-6 text-slate-500 dark:text-slate-400">Loading events...</p>}
      {isError && <p className="mt-6 text-rose-600 dark:text-rose-400">{String(error)}</p>}

      {data && (
        <>
          <div className="mt-6 overflow-x-auto rounded-lg border border-slate-200 dark:border-slate-800">
            <table className="w-full text-left text-sm">
              <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500 dark:bg-slate-900 dark:text-slate-400">
                <tr>
                  <th className="px-4 py-3 font-medium">#</th>
                  <th className="px-4 py-3 font-medium">Start (brake, pipe)</th>
                  <th className="px-4 py-3 font-medium">MBP / BC / WV</th>
                  <th className="px-4 py-3 font-medium">Total power eff.</th>
                  <th className="px-4 py-3 font-medium">Max P (pipe/cyl)</th>
                  <th className="px-4 py-3 font-medium">Non-standard</th>
                  <th className="px-4 py-3 font-medium">Errors</th>
                  <th className="px-4 py-3 font-medium">Predicted</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-200 dark:divide-slate-800">
                {data.events.map((ev) => (
                  <tr key={ev.event_id} className="bg-white hover:bg-slate-50 dark:bg-slate-950 dark:hover:bg-slate-900">
                    <td className="px-4 py-3">
                      <Link
                        to={`/kits/${kitId}/events/${ev.event_id}`}
                        className="text-sky-600 hover:underline dark:text-sky-400"
                      >
                        {ev.PhaseIdx ?? ev.event_id}
                      </Link>
                    </td>
                    <td className="px-4 py-3 text-slate-500 dark:text-slate-400">{ev.Start_brake_time_pipe}</td>
                    <td className="px-4 py-3 font-mono text-xs">{ev.MBP_ID} / {ev.BC_ID} / {ev.WV_ID}</td>
                    <td className="px-4 py-3">{ev.Total_power_efficiency?.toFixed?.(3) ?? '—'}</td>
                    <td className="px-4 py-3">
                      {ev.Max_pressure_pipe?.toFixed?.(2)} / {ev.Max_pressure_cyl?.toFixed?.(2)}
                    </td>
                    <td className="px-4 py-3">{ev.Non_Standard_Braking ? 'yes' : 'no'}</td>
                    <td className="px-4 py-3">
                      {[ev.MBP_Sensor_error, ev.BC_SensorError, ev.WV_SensorError].some(Boolean) ? (
                        <span className="text-amber-500">⚠</span>
                      ) : null}
                    </td>
                    <td className="px-4 py-3">
                      {ev.predicted_leakage === undefined || ev.predicted_leakage === null ? (
                        <span className="text-slate-400">—</span>
                      ) : ev.predicted_leakage ? (
                        <span className="inline-flex items-center rounded-full bg-rose-100 px-2 py-0.5 text-xs font-medium text-rose-800 dark:bg-rose-500/20 dark:text-rose-300">
                          leakage
                        </span>
                      ) : (
                        <span className="inline-flex items-center rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-800 dark:bg-emerald-500/20 dark:text-emerald-300">
                          healthy
                        </span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="mt-4 flex items-center gap-4 text-sm">
            <button
              disabled={page === 0}
              onClick={() => setPage((p) => p - 1)}
              className="rounded-md border border-slate-300 px-3 py-1.5 disabled:opacity-40 dark:border-slate-700"
            >
              Prev
            </button>
            <span className="text-slate-500 dark:text-slate-400">
              {data.offset + 1}-{Math.min(data.offset + data.limit, data.total)} of {data.total}
            </span>
            <button
              disabled={data.offset + data.limit >= data.total}
              onClick={() => setPage((p) => p + 1)}
              className="rounded-md border border-slate-300 px-3 py-1.5 disabled:opacity-40 dark:border-slate-700"
            >
              Next
            </button>
          </div>
        </>
      )}
    </div>
  )
}
