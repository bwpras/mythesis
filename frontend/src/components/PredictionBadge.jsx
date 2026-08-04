// predicted: 0/1/null/undefined (predicted_leakage). inScope: true/false/undefined
// (prediction_in_scope) -- undefined means the CSV row predates this field, or
// no model has ever run against it; that case falls back to a bare dash,
// same as before this existed. Status color always ships with an icon +
// label, never alone (dataviz skill's status-palette rule) -- amber matches
// this app's existing "warning" convention (see LivePage.jsx's last_error).
export default function PredictionBadge({ predicted, inScope }) {
  const isScored = predicted !== undefined && predicted !== null

  if (isScored) {
    return predicted ? (
      <span className="inline-flex items-center rounded-full bg-rose-100 px-2 py-0.5 text-xs font-medium text-rose-800 dark:bg-rose-500/20 dark:text-rose-300">
        leakage
      </span>
    ) : (
      <span className="inline-flex items-center rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-800 dark:bg-emerald-500/20 dark:text-emerald-300">
        healthy
      </span>
    )
  }

  if (inScope === false) {
    return (
      <span
        className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-500/20 dark:text-amber-300"
        title="This cycle's WV pressure, braking regularity, or BC start falls outside the model's validated regime -- no prediction is made for it."
      >
        <span aria-hidden="true">⚠</span> out of scope
      </span>
    )
  }

  return <span className="text-slate-400">—</span>
}
