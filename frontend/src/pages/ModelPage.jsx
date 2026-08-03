import { useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { getModelInfo } from '../api/client'

export default function ModelPage() {
  const { kitId } = useParams()

  const { data: model, isLoading, isError, error } = useQuery({
    queryKey: ['model', kitId],
    queryFn: () => getModelInfo(kitId),
  })

  if (isLoading) return <p>Loading model info...</p>
  if (isError) return <p style={{ color: 'crimson' }}>{String(error)}</p>

  const metrics = model.test_metrics || {}

  return (
    <div>
      <h1>Active leakage model</h1>
      <p>
        <strong>{model.model_name}</strong> — trained on features: {model.features.join(', ')}
      </p>
      <p>Saved at: {model.saved_at}</p>

      <h2>Held-out test metrics</h2>
      <p style={{ color: '#a05a00', maxWidth: 640 }}>
        Trained on only ~45 labeled reference rows (36 healthy / 23 leakage,
        pre-split) — near-perfect scores here reflect that small sample size,
        not proven generalization to real field data.
      </p>
      <table className="detail-table">
        <tbody>
          {Object.entries(metrics).map(([key, value]) => (
            <tr key={key}>
              <td className="key">{key}</td>
              <td>{String(value)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
