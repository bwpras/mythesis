import { NavLink, Route, Routes } from 'react-router-dom'
import OverviewPage from './pages/OverviewPage.jsx'
import KitDetailPage from './pages/KitDetailPage.jsx'
import EventDetailPage from './pages/EventDetailPage.jsx'
import ModelPage from './pages/ModelPage.jsx'
import JobsPage from './pages/JobsPage.jsx'
import './App.css'

function App() {
  return (
    <div className="app-shell">
      <nav className="app-nav">
        <span className="app-title">Railway Braking Dashboard</span>
        <NavLink to="/" end>Overview</NavLink>
        <NavLink to="/kits/Dati01">Dati01</NavLink>
        <NavLink to="/kits/Dati01/model">Model</NavLink>
        <NavLink to="/jobs">Jobs</NavLink>
      </nav>
      <main className="app-main">
        <Routes>
          <Route path="/" element={<OverviewPage />} />
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
