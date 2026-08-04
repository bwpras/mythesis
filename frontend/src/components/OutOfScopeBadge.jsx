// Shared visual for "a model is active, but this falls outside its
// validated regime (WV_bin/BC_BadStart/Non_Standard_Braking)" -- used both
// per-event (PredictionBadge.jsx) and per-kit (DiagnosticsPage.jsx's
// fleet-level predicted-leakage column). Status color always ships with an
// icon + label, never alone (dataviz skill's status-palette rule); amber
// matches this app's existing "warning" convention (see LivePage.jsx's
// last_error display).
export default function OutOfScopeBadge({ title }) {
  return (
    <span
      className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-500/20 dark:text-amber-300"
      title={title}
    >
      <span aria-hidden="true">⚠</span> out of scope
    </span>
  )
}
