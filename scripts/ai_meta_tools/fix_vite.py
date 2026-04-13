filepath = "repos/gui/vite.config.js"
content = """import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Support either gateway mode (default) or direct noetl-server mode
let apiMode = process.env.VITE_API_MODE;
if (apiMode !== "direct") {
  apiMode = "gateway";
}

let gatewayUrl = process.env.VITE_GATEWAY_URL || process.env.VITE_API_BASE_URL;
if (!gatewayUrl) {
  gatewayUrl = apiMode === "direct" ? "http://localhost:8082" : "http://localhost:8090";
}
console.log(`VITE_API_MODE=${apiMode} URL=${gatewayUrl}`)

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    sourcemap: true,
  },
  server: {
    port: 3001,
  },
  define: {
    __FASTAPI_URL__: JSON.stringify(`${gatewayUrl.replace(/\\/+$/, "")}/api`)
  }
})
"""
with open(filepath, "w") as f:
    f.write(content)
