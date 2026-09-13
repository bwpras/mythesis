import { useQuery } from '@tanstack/react-query'
import { Link, useNavigate } from 'react-router-dom'
import { MapContainer, TileLayer, Marker, Tooltip } from 'react-leaflet'
import 'leaflet/dist/leaflet.css'
import { listKits, getFleetDiagnostics } from '../api/client'
import { TILE_URL, TILE_ATTRIBUTION, FALLBACK_CENTER, dotIcon } from '../components/mapUtils'
import OutOfScopeBadge from '../components/OutOfScopeBadge.jsx'

const wagonBadgeClass = {
  T3000: 'bg-indigo-100 text-indigo-800 dark:bg-indigo-500/20 dark:text-indigo-300',
  '4909': 'bg-teal-100 text-teal-800 dark:bg-teal-500/20 dark:text-teal-300',
  '4575': 'bg-amber-100 text-amber-800 dark:bg-amber-500/20 dark:text-amber-300',
}

function WagonBadge({ type }) {
  const cls = wagonBadgeClass[type] || 'bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-300'
  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${cls}`}>
      {type}
    </span>
  )
}

function OverviewMap() {
  const navigate = useNavigate()
  const { data: kits } = useQuery({
    queryKey: ['fleet-diagnostics'],
    queryFn: getFleetDiagnostics,
  })

  if (!kits) return null
  const located = kits.filter((k) => k.last_location)
  if (located.length === 0) return null

  const center = [located[0].last_location.lat, located[0].last_location.lon]

  return (
    <div className="mt-6 h-72 overflow-hidden rounded-lg border border-slate-200 dark:border-slate-800">
      <MapContainer center={center} zoom={6} style={{ height: '100%', width: '100%' }}>
        <TileLayer attribution={TILE_ATTRIBUTION} url={TILE_URL} />
        {located.map((k) => (
          <Marker
            key={k.kit_id}
            position={[k.last_location.lat, k.last_location.lon]}
            icon={dotIcon('neutral')}
            eventHandlers={{ click: () => navigate(`/kits/${k.kit_id}`) }}
          >
            <Tooltip direction="top" offset={[0, -8]}>{k.kit_id} — click to open</Tooltip>
          </Marker>
        ))}
      </MapContainer>
    </div>
  )
}

export default function OverviewPage() {
  const { data: kits, isLoading, isError, error } = useQuery({
    queryKey: ['kits'],
    queryFn: listKits,
  })

  if (isLoading) return <p className="text-slate-500 dark:text-slate-400">Loading kits...</p>
  if (isError) return <p className="text-rose-600 dark:text-rose-400">{String(error)}</p>

  return (
    <div>
      <h1 className="text-2xl font-semibold tracking-tight">Fleet overview</h1>

      <div className="mt-3 rounded-lg border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-600 dark:border-slate-800 dark:bg-slate-900 dark:text-slate-400">
        <p>
          A continuation of the thesis <em>Development of Data Driven Fault Detection and Diagnostic
          of Freight Train Air Brake System</em>, focused on the monitoring dashboard itself &mdash;
          presenting the same pipeline and model results in a form that reads more clearly.
        </p>
        <p className="mt-2">
          <span className="font-medium text-slate-700 dark:text-slate-300">Disclaimer:</span>{' '}
          GPS coordinates shown here are spoofed, and only a portion of the dataset is served online.
        </p>
      </div>

      {kits.length === 0 && (
        <p className="mt-4 text-slate-500 dark:text-slate-400">
          No processed kits yet. Go to <Link to="/jobs" className="text-sky-600 hover:underline dark:text-sky-400">Jobs</Link> to
          run the pipeline for a kit first.
        </p>
      )}

      {kits.length > 0 && <OverviewMap />}

      <div className="mt-6 overflow-x-auto rounded-lg border border-slate-200 dark:border-slate-800">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500 dark:bg-slate-900 dark:text-slate-400">
            <tr>
              <th className="px-4 py-3 font-medium">Kit</th>
              <th className="px-4 py-3 font-medium">Wagon type</th>
              <th className="px-4 py-3 font-medium">Events</th>
              <th className="px-4 py-3 font-medium">Date range</th>
              <th className="px-4 py-3 font-medium">Non-standard braking</th>
              <th className="px-4 py-3 font-medium">Sensor errors</th>
              <th className="px-4 py-3 font-medium">Predicted leakage</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-200 dark:divide-slate-800">
            {kits.map((k) => (
              <tr key={k.kit_id} className="bg-white hover:bg-slate-50 dark:bg-slate-950 dark:hover:bg-slate-900">
                <td className="px-4 py-3 font-medium">
                  <Link to={`/kits/${k.kit_id}`} className="text-sky-600 hover:underline dark:text-sky-400">
                    {k.kit_id}
                  </Link>
                </td>
                <td className="px-4 py-3"><WagonBadge type={k.wagon_type} /></td>
                <td className="px-4 py-3">{k.event_count}</td>
                <td className="px-4 py-3 text-slate-500 dark:text-slate-400">
                  {k.date_range[0]?.slice(0, 11)} → {k.date_range[1]?.slice(0, 11)}
                </td>
                <td className="px-4 py-3">
                  {k.non_standard_count} ({((k.non_standard_count / k.event_count) * 100).toFixed(0)}%)
                </td>
                <td className="px-4 py-3">{k.sensor_error_count}</td>
                <td className="px-4 py-3">
                  {k.predicted_leakage_count !== null ? (
                    `${k.predicted_leakage_count} (${((k.predicted_leakage_count / k.event_count) * 100).toFixed(0)}%)`
                  ) : k.model_active ? (
                    <OutOfScopeBadge title="No events for this kit fall within the model's validated regime (WV pressure, braking regularity, BC start) -- nothing to score." />
                  ) : (
                    <span className="text-slate-400">no model yet</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
