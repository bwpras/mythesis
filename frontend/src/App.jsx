import { NavLink, Route, Routes } from 'react-router-dom'
import OverviewPage from './pages/OverviewPage.jsx'
import KitDetailPage from './pages/KitDetailPage.jsx'
import EventDetailPage from './pages/EventDetailPage.jsx'
import ModelPage from './pages/ModelPage.jsx'
import JobsPage from './pages/JobsPage.jsx'
import DiagnosticsPage from './pages/DiagnosticsPage.jsx'

const navLinkClass = ({ isActive }) =>
  `px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
    isActive
      ? 'bg-sky-100 text-sky-900 dark:bg-sky-500/20 dark:text-sky-300'
      : 'text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800'
  }`

function App() {
  return (
    <div className="min-h-screen bg-slate-50 text-slate-900 dark:bg-slate-950 dark:text-slate-100">
      <nav className="flex items-center gap-2 border-b border-slate-200 bg-white px-6 py-3 dark:border-slate-800 dark:bg-slate-900">
        <span className="mr-auto text-sm font-semibold tracking-tight text-slate-900 dark:text-white">
          Railway Braking Monitoring
        </span>
        <NavLink to="/" end className={navLinkClass}>Overview</NavLink>
        <NavLink to="/diagnostics" className={navLinkClass}>Diagnostics</NavLink>
        <NavLink to="/jobs" className={navLinkClass}>Jobs</NavLink>
      </nav>
      <main className="mx-auto max-w-6xl px-6 py-8">
        <Routes>
          <Route path="/" element={<OverviewPage />} />
          <Route path="/diagnostics" element={<DiagnosticsPage />} />
          <Route path="/kits/:kitId" element={<KitDetailPage />} />
          <Route path="/kits/:kitId/events/:eventId" element={<EventDetailPage />} />
          <Route path="/kits/:kitId/model" element={<ModelPage />} />
          <Route path="/jobs" element={<JobsPage />} />
        </Routes>
      </main>
    </div>
  )
}

export default App
