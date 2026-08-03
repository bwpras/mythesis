import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      // Dev-only: forwards /api/* to the FastAPI backend so the frontend
      // never needs to know the backend's host/port. A real deployment
      // would put a reverse proxy (nginx, etc.) in this same role.
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
    },
  },
})
