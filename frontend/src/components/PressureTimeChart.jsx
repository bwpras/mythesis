import { useMemo, useState, useEffect } from 'react'
import Plot from 'react-plotly.js'

// Categorical palette, slots 1-5 (blue, orange, aqua, yellow, magenta) --
// validated for CVD-safe adjacent contrast on a line chart (dataviz
// skill's reference palette; light/dark step per mode). MBP always takes
// slot 1 (the reference/pipe pressure); BC channels take slots 2-5 in the
// order they're returned, capped at 4 since a kit has at most 4 BC sensors.
const SERIES_COLORS_LIGHT = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4']
const SERIES_COLORS_DARK = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181']

function useIsDarkMode() {
  const [isDark, setIsDark] = useState(
    () => typeof window !== 'undefined' && window.matchMedia?.('(prefers-color-scheme: dark)').matches
  )
  useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)')
    const onChange = (e) => setIsDark(e.matches)
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [])
  return isDark
}

// series: { mbp: {label, time, pressure}, bc: [{id, label, time, pressure}, ...] }
export default function PressureTimeChart({ series }) {
  const isDark = useIsDarkMode()
  const colors = isDark ? SERIES_COLORS_DARK : SERIES_COLORS_LIGHT
  const ink = isDark ? '#ffffff' : '#0b0b0b'
  const secondaryInk = isDark ? '#c3c2b7' : '#52514e'
  const gridline = isDark ? '#2c2c2a' : '#e1e0d9'
  const surface = 'rgba(0,0,0,0)' // transparent -- inherits the card's own surface

  const traces = useMemo(() => {
    if (!series) return []
    const lines = [
      { name: series.mbp?.label || 'MBP', time: series.mbp?.time, pressure: series.mbp?.pressure },
      ...(series.bc || []).slice(0, 4).map((bc) => ({ name: bc.label || `BC ${bc.id}`, time: bc.time, pressure: bc.pressure })),
    ]
    return lines
      .filter((l) => l.time && l.time.length > 0)
      .map((l, i) => ({
        x: l.time,
        y: l.pressure,
        type: 'scatter',
        mode: 'lines',
        name: l.name,
        line: { width: 2, color: colors[i % colors.length], shape: 'linear' },
        hovertemplate: '%{y:.3f} bar<extra>' + l.name + '</extra>',
      }))
  }, [series, colors])

  if (!series || traces.length === 0) {
    return (
      <div className="flex h-72 items-center justify-center rounded-lg border border-slate-200 text-sm text-slate-400 dark:border-slate-800">
        No pressure history stored for this cycle.
      </div>
    )
  }

  return (
    <div className="h-72 overflow-hidden rounded-lg border border-slate-200 dark:border-slate-800">
      <Plot
        data={traces}
        layout={{
          autosize: true,
          margin: { l: 48, r: 16, t: 16, b: 40 },
          paper_bgcolor: surface,
          plot_bgcolor: surface,
          font: { family: 'system-ui, -apple-system, "Segoe UI", sans-serif', color: secondaryInk, size: 12 },
          xaxis: {
            type: 'date',
            gridcolor: gridline,
            zerolinecolor: gridline,
            linecolor: gridline,
            tickfont: { color: secondaryInk },
          },
          yaxis: {
            title: { text: 'Pressure (bar)', font: { color: secondaryInk } },
            gridcolor: gridline,
            zerolinecolor: gridline,
            linecolor: gridline,
            tickfont: { color: secondaryInk },
          },
          legend: {
            orientation: 'h',
            y: -0.25,
            font: { color: ink },
          },
          hovermode: 'x unified',
        }}
        config={{ displayModeBar: false, responsive: true }}
        style={{ width: '100%', height: '100%' }}
        useResizeHandler
      />
    </div>
  )
}
