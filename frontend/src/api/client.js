import axios from 'axios'

// Relative base: Vite's dev proxy (vite.config.js) forwards this to FastAPI,
// and a real deployment would put a reverse proxy in the same role -- the
// frontend never hardcodes a backend host/port.
export const api = axios.create({ baseURL: '/api' })

export async function startIngestJob({ kitId, startDate, endDate }) {
  const { data } = await api.post('/jobs/ingest', {
    kit_id: kitId,
    start_date: startDate,
    end_date: endDate,
  })
  return data
}

export async function getJob(jobId) {
  const { data } = await api.get(`/jobs/${jobId}`)
  return data
}

export async function listKits() {
  const { data } = await api.get('/kits')
  return data
}

export async function getKit(kitId) {
  const { data } = await api.get(`/kits/${kitId}`)
  return data
}

export async function listEvents(kitId, { offset = 0, limit = 50 } = {}) {
  const { data } = await api.get(`/kits/${kitId}/events`, { params: { offset, limit } })
  return data
}

export async function getEvent(kitId, eventId) {
  const { data } = await api.get(`/kits/${kitId}/events/${eventId}`)
  return data
}

export async function getModelInfo() {
  const { data } = await api.get('/model')
  return data
}

export async function getFleetDiagnostics() {
  const { data } = await api.get('/diagnostics')
  return data
}

export async function getKitDiagnostics(kitId) {
  const { data } = await api.get(`/diagnostics/${kitId}`)
  return data
}
