import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { MapContainer, TileLayer, Marker, Popup } from 'react-leaflet'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { getFleetDiagnostics } from '../api/client'

const STATUS_COLOR = {
  healthy: '#059669',   // emerald-600
  warning: '#d97706',   // amber-600
  critical: '#e11d48',  // rose-600
  unknown: '#94a3b8',   // slate-400
}

const STATUS_BADGE = {
  healthy: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-500/20 dark:text-emerald-300',
  warning: 'bg-amber-100 text-amber-800 dark:bg-amber-500/20 dark:text-amber-300',
  critical: 'bg-rose-100 text-rose-800 dark:bg-rose-500/20 dark:text-rose-300',
  unknown: 'bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-400',
}

function StatusBadge({ status }) {
  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_BADGE[status] || STATUS_BADGE.unknown}`}>
      {status}
    </span>
  )
}

function markerIcon(status) {
  const color = STATUS_COLOR[status] || STATUS_COLOR.unknown
  return L.divIcon({
    className: '',
    html: `<div style="width:16px;height:16px;border-radius:50%;background:${color};border:2px solid white;box-shadow:0 0 0 1px rgba(0,0,0,0.3)"></div>`,
    iconSize: [16, 16],
    iconAnchor: [8, 8],
  })
}

// Worst of airbrake/GPS status decides marker color -- a kit with a
// healthy airbrake system but no GPS coverage still needs attention.
function worstStatus(kit) {
  const order = { healthy: 0, unknown: 1, warning: 2, critical: 3 }
  const a = kit.airbrake_health.status
  const g = kit.gps_health.status
  return order[a] >= order[g] ? a : g
}

export default function DiagnosticsPage() {
  const { data: kits, isLoading, isError, error } = useQuery({
    queryKey: ['fleet-diagnostics'],
    queryFn: getFleetDiagnostics,
  })

  if (isLoading) return <p className="text-slate-500 dark:text-slate-400">Loading diagnostics...</p>
  if (isError) return <p className="text-rose-600 dark:text-rose-400">{String(error)}</p>

  const located = kits.filter((k) => k.last_location)
  const center = located.length
    ? [located[0].last_location.lat, located[0].last_location.lon]
    : [45.46, 9.19] // fallback: Northern Italy, this fleet's operating region

  return (
    <div>
      <h1 className="text-2xl font-semibold tracking-tight">Fleet diagnostics</h1>
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">
        Airbrake system health (sensor errors, non-standard braking, predicted leakage) and GPS health
        (sensor coverage) per kit, plus last-known location.
      </p>

      <div className="mt-6 h-96 overflow-hidden rounded-lg border border-slate-200 dark:border-slate-800">
        <MapContainer center={center} zoom={7} style={{ height: '100%', width: '100%' }}>
          <TileLayer
            attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
          />
          {located.map((k) => (
            <Marker
              key={k.kit_id}
              position={[k.last_location.lat, k.last_location.lon]}
              icon={markerIcon(worstStatus(k))}
            >
              <Popup>
                <div className="text-sm">
                  <Link to={`/kits/${k.kit_id}`} className="font-semibold text-sky-600">{k.kit_id}</Link>
                  <div>{k.wagon_type}</div>
                  <div>Airbrake: {k.airbrake_health.status}</div>
                  <div>GPS: {k.gps_health.status}</div>
                  <div className="text-xs text-slate-500">{k.last_location.time}</div>
                </div>
              </Popup>
            </Marker>
          ))}
        </MapContainer>
      </div>

      <div className="mt-8 overflow-x-auto rounded-lg border border-slate-200 dark:border-slate-800">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500 dark:bg-slate-900 dark:text-slate-400">
            <tr>
              <th className="px-4 py-3 font-medium">Kit</th>
              <th className="px-4 py-3 font-medium">Wagon</th>
              <th className="px-4 py-3 font-medium">Airbrake health</th>
              <th className="px-4 py-3 font-medium">Sensor errors</th>
              <th className="px-4 py-3 font-medium">Predicted leakage</th>
              <th className="px-4 py-3 font-medium">GPS health</th>
              <th className="px-4 py-3 font-medium">GPS errors</th>
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
                <td className="px-4 py-3">{k.wagon_type}</td>
                <td className="px-4 py-3"><StatusBadge status={k.airbrake_health.status} /></td>
                <td className="px-4 py-3">{k.airbrake_health.sensor_error_pct}%</td>
                <td className="px-4 py-3">
                  {k.airbrake_health.predicted_leakage_pct === null
                    ? <span className="text-slate-400">—</span>
                    : `${k.airbrake_health.predicted_leakage_pct}%`}
                </td>
                <td className="px-4 py-3"><StatusBadge status={k.gps_health.status} /></td>
                <td className="px-4 py-3">
                  {k.gps_health.gps_error_pct === null
                    ? <span className="text-slate-400">—</span>
                    : `${k.gps_health.gps_error_pct}%`}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
