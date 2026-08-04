import { MapContainer, TileLayer, Marker } from 'react-leaflet'
import 'leaflet/dist/leaflet.css'
import { TILE_URL, TILE_ATTRIBUTION, dotIcon } from './mapUtils'

// Extracted from EventDetailPage.jsx so LiveEventDetailPage.jsx can reuse
// it unchanged -- both read the same GPS_Lat_last/GPS_Long_last scalar
// fields (present in KEEP_FIELDS for both the batch and live CSVs).
export default function EventMiniMap({ event }) {
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
