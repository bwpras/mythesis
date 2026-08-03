import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { listKits } from '../api/client'

export default function OverviewPage() {
  const { data: kits, isLoading, isError, error } = useQuery({
    queryKey: ['kits'],
    queryFn: listKits,
  })

  if (isLoading) return <p>Loading kits...</p>
  if (isError) return <p style={{ color: 'crimson' }}>{String(error)}</p>

  return (
    <div>
      <h1>Fleet overview</h1>
      {kits.length === 0 && (
        <p>
          No processed kits yet. Go to <Link to="/jobs">Jobs</Link> to run the pipeline
          for a kit first.
        </p>
      )}
      <table className="kit-table">
        <thead>
          <tr>
            <th>Kit</th>
            <th>Events</th>
            <th>Date range</th>
            <th>Non-standard braking</th>
            <th>Sensor errors</th>
            <th>Predicted leakage</th>
          </tr>
        </thead>
        <tbody>
          {kits.map((k) => (
            <tr key={k.kit_id}>
              <td><Link to={`/kits/${k.kit_id}`}>{k.kit_id}</Link></td>
              <td>{k.event_count}</td>
              <td>{k.date_range[0]?.slice(0, 10)} → {k.date_range[1]?.slice(0, 10)}</td>
              <td>{k.non_standard_count} ({((k.non_standard_count / k.event_count) * 100).toFixed(0)}%)</td>
              <td>{k.sensor_error_count}</td>
              <td>
                {k.predicted_leakage_count === null
                  ? 'no model yet'
                  : `${k.predicted_leakage_count} (${((k.predicted_leakage_count / k.event_count) * 100).toFixed(0)}%)`}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
