import { useQuery } from '@tanstack/react-query'
import { getModelInfo } from '../api/client'

export default function ModelPage() {
  const { data: model, isLoading, isError, error } = useQuery({
    queryKey: ['model'],
    queryFn: () => getModelInfo(),
  })

  if (isLoading) return <p className="text-slate-500 dark:text-slate-400">Loading model info...</p>
  if (isError) return <p className="text-rose-600 dark:text-rose-400">{String(error)}</p>

  const farRows = model.far_by_wagon_type || []

  return (
    <div>
      <h1 className="text-2xl font-semibold tracking-tight">Active leakage model</h1>
      <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
        <span className="font-semibold">{model.model_name}</span> — features: {model.features?.join(', ')}
      </p>
      <p className="mt-4 max-w-2xl rounded-md bg-amber-50 px-4 py-3 text-sm text-amber-800 dark:bg-amber-500/10 dark:text-amber-300">
        Trained on only ~45 labeled bench-reference rows. The model here is chosen by the lowest mean
        False Alarm Rate (below) against real, in-service field data — a much more meaningful check than
        a held-out split of the tiny training set.
      </p>

      <h2 className="mt-8 text-lg font-semibold tracking-tight">
        False Alarm Rate by wagon type (generalization test)
      </h2>
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">
        Every model scored against real, presumed-healthy field data (Dati30 + other-wagon-type kits) —
        a &quot;leakage&quot; prediction here is a false alarm by construction.
      </p>
      <div className="mt-4 overflow-x-auto rounded-lg border border-slate-200 dark:border-slate-800">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500 dark:bg-slate-900 dark:text-slate-400">
            <tr>
              <th className="px-4 py-3 font-medium">Model</th>
              <th className="px-4 py-3 font-medium">Wagon type</th>
              <th className="px-4 py-3 font-medium">False positives</th>
              <th className="px-4 py-3 font-medium">Total samples</th>
              <th className="px-4 py-3 font-medium">FAR</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-200 dark:divide-slate-800">
            {farRows.map((r, i) => (
              <tr
                key={i}
                className={
                  r.Model === model.model_name
                    ? 'bg-sky-50 dark:bg-sky-500/10'
                    : 'bg-white dark:bg-slate-950'
                }
              >
                <td className="px-4 py-3 font-mono text-xs">{r.Model}</td>
                <td className="px-4 py-3">{r.WagonType}</td>
                <td className="px-4 py-3">{r.FP} / {r.TotalSamples}</td>
                <td className="px-4 py-3">{r.TotalSamples}</td>
                <td className="px-4 py-3 font-medium">{r.FalseAlarmRate_pct}%</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
