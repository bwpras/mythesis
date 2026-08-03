import { useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { listEvents, getKit } from '../api/client'

const PAGE_SIZE = 25

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
      <h1>{kitId}</h1>
      {summary && (
        <p>
          {summary.event_count} events · {summary.non_standard_count} non-standard ·{' '}
          {summary.sensor_error_count} with sensor errors ·{' '}
          <Link to={`/kits/${kitId}/model`}>model info</Link>
        </p>
      )}

      {isLoading && <p>Loading events...</p>}
      {isError && <p style={{ color: 'crimson' }}>{String(error)}</p>}

      {data && (
        <>
          <table className="event-table">
            <thead>
              <tr>
                <th>#</th>
                <th>Start (brake, pipe)</th>
                <th>MBP / BC / WV</th>
                <th>Total power eff.</th>
                <th>Max P (pipe/cyl)</th>
                <th>Non-standard</th>
                <th>Errors</th>
                <th>Predicted</th>
              </tr>
            </thead>
            <tbody>
              {data.events.map((ev) => (
                <tr key={ev.event_id}>
                  <td><Link to={`/kits/${kitId}/events/${ev.event_id}`}>{ev.PhaseIdx}</Link></td>
                  <td>{ev.Start_brake_time_pipe}</td>
                  <td>{ev.MBP_ID} / {ev.BC_ID} / {ev.WV_ID}</td>
                  <td>{ev.Total_power_efficiency?.toFixed?.(3) ?? '—'}</td>
                  <td>{ev.Max_pressure_pipe?.toFixed?.(2)} / {ev.Max_pressure_cyl?.toFixed?.(2)}</td>
                  <td>{ev.Non_Standard_Braking ? 'yes' : 'no'}</td>
                  <td>
                    {[ev.MBP_Sensor_error, ev.BC_SensorError, ev.WV_SensorError].some(Boolean)
                      ? '⚠' : ''}
                  </td>
                  <td>
                    {ev.predicted_leakage === undefined || ev.predicted_leakage === null
                      ? '—'
                      : ev.predicted_leakage
                        ? <span style={{ color: 'crimson' }}>leakage</span>
                        : 'healthy'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>

          <div className="pager">
            <button disabled={page === 0} onClick={() => setPage((p) => p - 1)}>Prev</button>
            <span>
              {data.offset + 1}-{Math.min(data.offset + data.limit, data.total)} of {data.total}
            </span>
            <button
              disabled={data.offset + data.limit >= data.total}
              onClick={() => setPage((p) => p + 1)}
            >
              Next
            </button>
          </div>
        </>
      )}
    </div>
  )
}
