import L from 'leaflet'

export const TILE_URL = 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png'
export const TILE_ATTRIBUTION =
  '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'

export const STATUS_COLOR = {
  healthy: '#059669',   // emerald-600
  warning: '#d97706',   // amber-600
  critical: '#e11d48',  // rose-600
  unknown: '#94a3b8',   // slate-400
  neutral: '#0284c7',   // sky-600 -- plain marker, no health status attached
}

// clickable=true adds a pointer cursor -- every marker in this app either
// drills down to a kit or an event on click, or (EventDetailPage's single
// marker) is already the deepest level, so it's opt-out per call site
// rather than universal.
export function dotIcon(status = 'neutral', size = 16, clickable = true) {
  const color = STATUS_COLOR[status] || STATUS_COLOR.neutral
  const cursor = clickable ? 'cursor:pointer;' : ''
  return L.divIcon({
    className: '',
    html: `<div style="width:${size}px;height:${size}px;border-radius:50%;background:${color};border:2px solid white;box-shadow:0 0 0 1px rgba(0,0,0,0.3);${cursor}"></div>`,
    iconSize: [size, size],
    iconAnchor: [size / 2, size / 2],
  })
}

// Fallback map center when there's no located data yet: this fleet's real
// operating region (Northern Italy / Alps), not [0,0].
export const FALLBACK_CENTER = [45.46, 9.19]
