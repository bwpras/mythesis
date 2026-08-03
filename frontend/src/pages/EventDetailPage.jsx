import { useParams, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { getEvent } from '../api/client'

export default function EventDetailPage() {
  const { kitId, eventId } = useParams()

  const { data: event, isLoading, isError, error } = useQuery({
    queryKey: ['event', kitId, eventId],
    queryFn: () => getEvent(kitId, Number(eventId)),
  })

  if (isLoading) return <p>Loading event...</p>
  if (isError) return <p style={{ color: 'crimson' }}>{String(error)}</p>

  return (
    <div>
      <p><Link to={`/kits/${kitId}`}>← back to {kitId}</Link></p>
      <h1>Event #{event.PhaseIdx} — {kitId}</h1>
      <table className="detail-table">
        <tbody>
          {Object.entries(event).map(([key, value]) => (
            <tr key={key}>
              <td className="key">{key}</td>
              <td>{value === null || value === undefined ? '—' : String(value)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
