#!/usr/bin/env bash
set -euo pipefail

# One-click deployment for Tencent Cloud Ubuntu/Debian:
# - Chromium remote browser (CDP)
# - FastAPI metadata endpoint with Bearer token auth
# - systemd services
#
# Usage:
#   sudo bash deploy_tencent_remote_browser.sh
#
# Optional env vars:
#   CDP_PORT=9222
#   API_PORT=8787
#   BIND_ADDRESS=0.0.0.0
#   PUBLIC_HOST=<server-public-ip-or-domain>
#   API_TOKEN=<custom-bearer-token>
#   OPEN_UFW=1  # auto-open API/CDP ports with ufw if installed

if [[ "${EUID}" -ne 0 ]]; then
	echo "Please run as root: sudo bash $0"
	exit 1
fi

log() {
	printf '[deploy] %s\n' "$*"
}

CDP_PORT="${CDP_PORT:-9222}"
API_PORT="${API_PORT:-8787}"
BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
INSTALL_DIR="${INSTALL_DIR:-/opt/remote-browser}"
PROFILE_DIR="${PROFILE_DIR:-/var/lib/remote-browser/profile}"
SERVICE_USER="${SERVICE_USER:-remote-browser}"

DETECTED_IP="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
if [[ -z "${DETECTED_IP}" ]]; then
	DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
PUBLIC_HOST="${PUBLIC_HOST:-${DETECTED_IP:-127.0.0.1}}"

API_TOKEN="${API_TOKEN:-}"
if [[ -z "${API_TOKEN}" ]]; then
	if command -v openssl >/dev/null 2>&1; then
		API_TOKEN="$(openssl rand -hex 24)"
	else
		API_TOKEN="$(date +%s | sha256sum | awk '{print $1}')"
	fi
fi

log "Updating apt indexes..."
apt-get update -y

log "Installing system dependencies..."
apt-get install -y curl ca-certificates xz-utils jq

if ! command -v chromium >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1 && ! command -v google-chrome >/dev/null 2>&1; then
	log "Installing Chromium..."
	apt-get install -y chromium-browser || apt-get install -y chromium
fi

CHROME_BIN="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"
if [[ -z "${CHROME_BIN}" ]]; then
	echo "Could not find chromium/google-chrome binary after installation."
	exit 1
fi
log "Using browser binary: ${CHROME_BIN}"

if ! command -v uv >/dev/null 2>&1; then
	log "Installing uv..."
	curl -LsSf https://astral.sh/uv/install.sh | sh
fi

UV_BIN="$(command -v uv || true)"
if [[ -z "${UV_BIN}" && -x "/root/.local/bin/uv" ]]; then
	UV_BIN="/root/.local/bin/uv"
fi
if [[ -z "${UV_BIN}" ]]; then
	echo "uv not found after installation."
	exit 1
fi
log "Using uv binary: ${UV_BIN}"

if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
	log "Creating service user: ${SERVICE_USER}"
	useradd --system --create-home --home-dir /var/lib/remote-browser --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

mkdir -p "${INSTALL_DIR}" "${PROFILE_DIR}"
chown -R "${SERVICE_USER}:${SERVICE_USER}" /var/lib/remote-browser

log "Creating API server code..."
cat > "${INSTALL_DIR}/api_server.py" <<'PY'
import os
from urllib.parse import urlparse, urlunparse

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException

app = FastAPI(title='Remote Browser Metadata API', version='1.0.0')

CDP_INTERNAL_PORT = int(os.getenv('REMOTE_BROWSER_CDP_PORT', '9222'))
PUBLIC_HOST = os.getenv('REMOTE_BROWSER_PUBLIC_HOST', '127.0.0.1')
API_TOKEN = os.getenv('REMOTE_BROWSER_API_TOKEN', '').strip()
CDP_INTERNAL_BASE = f'http://127.0.0.1:{CDP_INTERNAL_PORT}'
CDP_PUBLIC_HTTP = f'http://{PUBLIC_HOST}:{CDP_INTERNAL_PORT}'


def _rewrite_ws(ws_url: str) -> str:
	parsed = urlparse(ws_url)
	scheme = 'wss' if parsed.scheme == 'wss' else 'ws'
	return urlunparse((scheme, f'{PUBLIC_HOST}:{CDP_INTERNAL_PORT}', parsed.path, '', '', ''))


def _auth(authorization: str | None = Header(default=None)) -> None:
	if not API_TOKEN:
		return
	if authorization != f'Bearer {API_TOKEN}':
		raise HTTPException(status_code=401, detail='Unauthorized')


@app.get('/health')
async def health():
	return {'ok': True}


@app.get('/v1/browser/info', dependencies=[Depends(_auth)])
async def browser_info():
	async with httpx.AsyncClient(timeout=10.0) as client:
		resp = await client.get(f'{CDP_INTERNAL_BASE}/json/version')
		resp.raise_for_status()
		data = resp.json()

	ws_internal = data.get('webSocketDebuggerUrl', '')
	ws_public = _rewrite_ws(ws_internal) if ws_internal else ''

	return {
		'cdp_http_url': CDP_PUBLIC_HTTP,
		'cdp_json_version_url': f'{CDP_PUBLIC_HTTP}/json/version',
		'cdp_ws_url': ws_public,
		'browser': data.get('Browser'),
		'protocol_version': data.get('Protocol-Version'),
		'user_agent': data.get('User-Agent'),
	}


@app.get('/v1/browser/json/version', dependencies=[Depends(_auth)])
async def browser_json_version():
	async with httpx.AsyncClient(timeout=10.0) as client:
		resp = await client.get(f'{CDP_INTERNAL_BASE}/json/version')
		resp.raise_for_status()
		data = resp.json()
		if 'webSocketDebuggerUrl' in data:
			data['webSocketDebuggerUrl'] = _rewrite_ws(data['webSocketDebuggerUrl'])
		return data
PY

log "Creating API environment file..."
cat > "${INSTALL_DIR}/remote-browser.env" <<EOF
REMOTE_BROWSER_API_TOKEN=${API_TOKEN}
REMOTE_BROWSER_PUBLIC_HOST=${PUBLIC_HOST}
REMOTE_BROWSER_CDP_PORT=${CDP_PORT}
EOF
chmod 600 "${INSTALL_DIR}/remote-browser.env"

log "Creating Python venv with uv..."
cd "${INSTALL_DIR}"
"${UV_BIN}" venv --python 3.11
source "${INSTALL_DIR}/.venv/bin/activate"
"${UV_BIN}" pip install --upgrade fastapi uvicorn httpx
deactivate

chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"

log "Creating systemd service: remote-chromium.service"
cat > /etc/systemd/system/remote-chromium.service <<EOF
[Unit]
Description=Remote Chromium CDP Service
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=/var/lib/remote-browser
ExecStart=${CHROME_BIN} --headless=new --remote-debugging-address=${BIND_ADDRESS} --remote-debugging-port=${CDP_PORT} --user-data-dir=${PROFILE_DIR} --disable-dev-shm-usage --no-first-run --no-default-browser-check about:blank
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

log "Creating systemd service: remote-browser-api.service"
cat > /etc/systemd/system/remote-browser-api.service <<EOF
[Unit]
Description=Remote Browser Metadata API
After=network.target remote-chromium.service
Requires=remote-chromium.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/remote-browser.env
ExecStart=${INSTALL_DIR}/.venv/bin/uvicorn api_server:app --host ${BIND_ADDRESS} --port ${API_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

if [[ "${OPEN_UFW:-0}" == "1" ]] && command -v ufw >/dev/null 2>&1; then
	log "Opening firewall ports with ufw: ${CDP_PORT}, ${API_PORT}"
	ufw allow "${CDP_PORT}"/tcp || true
	ufw allow "${API_PORT}"/tcp || true
fi

log "Reloading systemd and starting services..."
systemctl daemon-reload
systemctl enable --now remote-chromium.service
systemctl enable --now remote-browser-api.service

log "Waiting for Chromium CDP endpoint..."
for i in $(seq 1 30); do
	if curl -fsS "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

echo
echo "================ Deployment Complete ================"
echo "API Health URL:"
echo "  http://${PUBLIC_HOST}:${API_PORT}/health"
echo
echo "Callable Interface (requires Bearer token):"
echo "  http://${PUBLIC_HOST}:${API_PORT}/v1/browser/info"
echo
echo "CDP Endpoint (for browser-use):"
echo "  http://${PUBLIC_HOST}:${CDP_PORT}"
echo
echo "Bearer Token:"
echo "  ${API_TOKEN}"
echo
echo "Test API:"
echo "  curl -H \"Authorization: Bearer ${API_TOKEN}\" http://${PUBLIC_HOST}:${API_PORT}/v1/browser/info"
echo
echo "Use in browser-use:"
echo "  browser = Browser(cdp_url='http://${PUBLIC_HOST}:${CDP_PORT}')"
echo "====================================================="
