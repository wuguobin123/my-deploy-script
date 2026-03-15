#!/usr/bin/env bash
set -euo pipefail

# One-click deployment for TencentOS/CentOS-like systems:
# - Chromium remote browser (CDP)
# - Xvfb virtual display
# - x11vnc + noVNC visualization
# - FastAPI metadata endpoint with Bearer token auth
# - systemd services
#
# Usage:
#   sudo bash deploy_tencent_remote_browser.sh
#
# Optional env vars:
#   CDP_PORT=9222
#   API_PORT=8787
#   VNC_PORT=5900
#   NOVNC_PORT=6080
#   DISPLAY_NUM=99
#   SCREEN_RESOLUTION=1920x1080x24
#   START_PAGE=<initial-visible-page-url>
#   BIND_ADDRESS=0.0.0.0
#   PUBLIC_HOST=<server-public-ip-or-domain>
#   API_TOKEN=<custom-bearer-token>
#   VNC_PASSWORD=<custom-vnc-password>
#   OPEN_UFW=1  # auto-open API/CDP/VNC/noVNC ports with ufw if installed

if [[ "${EUID}" -ne 0 ]]; then
	echo "Please run as root: sudo bash $0"
	exit 1
fi

log() {
	printf '[deploy] %s\n' "$*"
}

is_python_supported() {
	local py_bin="$1"
	"${py_bin}" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 8) else 1)
PY
}

find_supported_python() {
	local py
	for py in python3.11 python3.10 python3.9 python3.8 python3; do
		local py_bin
		py_bin="$(command -v "${py}" || true)"
		if [[ -n "${py_bin}" ]] && is_python_supported "${py_bin}"; then
			echo "${py_bin}"
			return 0
		fi
	done
	return 1
}

install_first_available_package() {
	local installed_pkg=""
	local pkg
	for pkg in "$@"; do
		if dnf install -y "${pkg}" >/dev/null 2>&1; then
			installed_pkg="${pkg}"
			break
		fi
	done
	if [[ -n "${installed_pkg}" ]]; then
		log "Installed package: ${installed_pkg}"
		return 0
	fi
	return 1
}

resolve_novnc_web_dir() {
	local d
	for d in \
		"/usr/share/novnc" \
		"/usr/share/novnc/noVNC" \
		"/usr/share/novnc/www" \
		"${INSTALL_DIR}/noVNC"; do
		if [[ -f "${d}/vnc.html" ]]; then
			echo "${d}"
			return 0
		fi
	done
	return 1
}

make_random_secret() {
	local length="$1"
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex 96 | cut -c1-"${length}"
	else
		date +%s%N | sha256sum | awk '{print $1}' | head -c "${length}"
	fi
}

CDP_PORT="${CDP_PORT:-9222}"
API_PORT="${API_PORT:-8787}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
SCREEN_RESOLUTION="${SCREEN_RESOLUTION:-1920x1080x24}"
START_PAGE="${START_PAGE:-data:text/html,%3Chtml%3E%3Cbody%20style=%22font-family:sans-serif;background:%23ffffff;color:%23000000;padding:32px%22%3E%3Ch2%3ERemote%20Browser%20Ready%3C/h2%3E%3Cp%3EWaiting%20for%20CDP%20automation...%3C/p%3E%3C/body%3E%3C/html%3E}"
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
	API_TOKEN="$(make_random_secret 48)"
fi

VNC_PASSWORD="${VNC_PASSWORD:-}"
if [[ -z "${VNC_PASSWORD}" ]]; then
	VNC_PASSWORD="$(make_random_secret 12)"
fi

if ! command -v dnf >/dev/null 2>&1; then
	echo "dnf not found. This script requires TencentOS/CentOS-like system with dnf."
	exit 1
fi

log "Updating dnf metadata..."
dnf makecache -y

log "Installing system dependencies..."
dnf install -y curl ca-certificates xz jq tar

log "Installing locale and common font dependencies..."
dnf install -y fontconfig glibc-langpack-en glibc-langpack-zh || true

log "Installing CJK fonts (for Chinese text rendering)..."
if ! install_first_available_package \
	google-noto-sans-cjk-ttc-fonts \
	google-noto-sans-cjk-sc-fonts \
	google-noto-cjk-fonts \
	wqy-zenhei-fonts \
	wqy-microhei-fonts; then
	log "WARNING: Could not install preferred CJK font package from current repositories."
fi

if command -v fc-cache >/dev/null 2>&1; then
	log "Refreshing font cache..."
	fc-cache -f >/dev/null 2>&1 || true
fi

if ! command -v chromium >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1 && ! command -v google-chrome >/dev/null 2>&1; then
	log "Installing Chromium..."
	dnf install -y chromium || dnf install -y chromium-browser
fi

CHROME_BIN="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"
if [[ -z "${CHROME_BIN}" ]]; then
	echo "Could not find chromium/google-chrome binary after installation."
	exit 1
fi
log "Using browser binary: ${CHROME_BIN}"

log "Installing Xvfb and x11vnc..."
dnf install -y xorg-x11-server-Xvfb x11vnc

log "Installing a lightweight window manager (openbox/fluxbox)..."
if ! install_first_available_package openbox fluxbox; then
	echo "Could not install a lightweight window manager (openbox/fluxbox)."
	exit 1
fi

XVFB_BIN="$(command -v Xvfb || true)"
X11VNC_BIN="$(command -v x11vnc || true)"
WM_BIN="$(command -v openbox || command -v fluxbox || true)"
if [[ -z "${XVFB_BIN}" || -z "${X11VNC_BIN}" || -z "${WM_BIN}" ]]; then
	echo "Could not find Xvfb/x11vnc/window-manager after installation."
	exit 1
fi
log "Using Xvfb binary: ${XVFB_BIN}"
log "Using x11vnc binary: ${X11VNC_BIN}"
log "Using window manager binary: ${WM_BIN}"

log "Trying to install noVNC static files via dnf..."
dnf install -y novnc >/dev/null 2>&1 || dnf install -y noVNC >/dev/null 2>&1 || true

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

PYTHON_BIN="$(find_supported_python || true)"
if [[ -z "${PYTHON_BIN}" ]]; then
	log "No Python 3.8+ found, installing one via dnf..."
	for pkg in python3.11 python3.10 python3.9 python3.8 python311 python310 python39 python38; do
		dnf install -y "${pkg}" >/dev/null 2>&1 || true
		PYTHON_BIN="$(find_supported_python || true)"
		if [[ -n "${PYTHON_BIN}" ]]; then
			break
		fi
	done
fi
if [[ -z "${PYTHON_BIN}" ]]; then
	echo "Could not find/install a supported Python (3.8+)."
	echo "Please install python3.8+ manually, then rerun this script."
	exit 1
fi
PYTHON_VER="$("${PYTHON_BIN}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')"
log "Using python binary: ${PYTHON_BIN} (${PYTHON_VER})"

if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
	log "Creating service user: ${SERVICE_USER}"
	useradd --system --create-home --home-dir /var/lib/remote-browser --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

mkdir -p "${INSTALL_DIR}" "${PROFILE_DIR}" /var/lib/remote-browser/.vnc
chown -R "${SERVICE_USER}:${SERVICE_USER}" /var/lib/remote-browser
chmod 700 /var/lib/remote-browser/.vnc

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
"${UV_BIN}" venv --python "${PYTHON_BIN}"
"${UV_BIN}" pip install --python "${INSTALL_DIR}/.venv/bin/python" --upgrade fastapi uvicorn httpx websockify

WEBSOCKIFY_BIN="$(command -v websockify || true)"
if [[ -z "${WEBSOCKIFY_BIN}" && -x "${INSTALL_DIR}/.venv/bin/websockify" ]]; then
	WEBSOCKIFY_BIN="${INSTALL_DIR}/.venv/bin/websockify"
fi
if [[ -z "${WEBSOCKIFY_BIN}" ]]; then
	echo "websockify is not available."
	exit 1
fi
log "Using websockify binary: ${WEBSOCKIFY_BIN}"

NOVNC_WEB_DIR="$(resolve_novnc_web_dir || true)"
if [[ -z "${NOVNC_WEB_DIR}" ]]; then
	log "noVNC package not found, downloading noVNC release..."
	NOVNC_TARBALL="/tmp/novnc-v1.5.0.tar.gz"
	curl -fsSL "https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz" -o "${NOVNC_TARBALL}"
	rm -rf "${INSTALL_DIR}/noVNC"
	tar -xzf "${NOVNC_TARBALL}" -C "${INSTALL_DIR}"
	mv "${INSTALL_DIR}"/noVNC-* "${INSTALL_DIR}/noVNC"
	NOVNC_WEB_DIR="${INSTALL_DIR}/noVNC"
fi
if [[ ! -f "${NOVNC_WEB_DIR}/vnc.html" ]]; then
	echo "Could not resolve noVNC web assets directory."
	exit 1
fi
log "Using noVNC web dir: ${NOVNC_WEB_DIR}"

VNC_PASS_FILE="/var/lib/remote-browser/.vnc/passwd"
log "Generating VNC password file..."
"${X11VNC_BIN}" -storepasswd "${VNC_PASSWORD}" "${VNC_PASS_FILE}" >/dev/null 2>&1
chmod 600 "${VNC_PASS_FILE}"
chown "${SERVICE_USER}:${SERVICE_USER}" "${VNC_PASS_FILE}"

chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"

log "Creating systemd service: remote-xvfb.service"
cat > /etc/systemd/system/remote-xvfb.service <<EOF
[Unit]
Description=Remote Browser Xvfb Display Service
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=/var/lib/remote-browser
ExecStart=${XVFB_BIN} :${DISPLAY_NUM} -screen 0 ${SCREEN_RESOLUTION} -ac +extension RANDR -nolisten tcp -dpi 96
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

log "Creating systemd service: remote-chromium.service"
cat > /etc/systemd/system/remote-chromium.service <<EOF
[Unit]
Description=Remote Chromium CDP Service
After=network.target remote-xvfb.service remote-wm.service
Requires=remote-xvfb.service remote-wm.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=/var/lib/remote-browser
Environment=DISPLAY=:${DISPLAY_NUM}
Environment=LANG=zh_CN.UTF-8
Environment=LC_ALL=zh_CN.UTF-8
Environment=LC_CTYPE=zh_CN.UTF-8
ExecStart=${CHROME_BIN} --lang=zh-CN --window-size=1920,1080 --window-position=0,0 --start-maximized --ozone-platform=x11 --remote-debugging-address=${BIND_ADDRESS} --remote-debugging-port=${CDP_PORT} --remote-allow-origins=* --user-data-dir=${PROFILE_DIR} --disable-dev-shm-usage --disable-gpu --disable-renderer-backgrounding --disable-backgrounding-occluded-windows --no-first-run --no-default-browser-check --no-sandbox --disable-setuid-sandbox ${START_PAGE}
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

log "Creating systemd service: remote-wm.service"
cat > /etc/systemd/system/remote-wm.service <<EOF
[Unit]
Description=Remote Browser Window Manager Service
After=remote-xvfb.service
Requires=remote-xvfb.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=/var/lib/remote-browser
Environment=DISPLAY=:${DISPLAY_NUM}
ExecStart=${WM_BIN}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

log "Creating systemd service: remote-vnc.service"
cat > /etc/systemd/system/remote-vnc.service <<EOF
[Unit]
Description=Remote Browser x11vnc Service
After=remote-xvfb.service remote-wm.service remote-chromium.service
Requires=remote-xvfb.service remote-wm.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=/var/lib/remote-browser
Environment=DISPLAY=:${DISPLAY_NUM}
ExecStart=${X11VNC_BIN} -display :${DISPLAY_NUM} -rfbport ${VNC_PORT} -rfbauth ${VNC_PASS_FILE} -listen ${BIND_ADDRESS} -forever -shared -noxrecord -noxfixes -noxdamage
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

log "Creating systemd service: remote-novnc.service"
cat > /etc/systemd/system/remote-novnc.service <<EOF
[Unit]
Description=Remote Browser noVNC Service
After=remote-vnc.service
Requires=remote-vnc.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${NOVNC_WEB_DIR}
ExecStart=${WEBSOCKIFY_BIN} --web=${NOVNC_WEB_DIR} ${BIND_ADDRESS}:${NOVNC_PORT} 127.0.0.1:${VNC_PORT}
Restart=always
RestartSec=2

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
ExecStart=${INSTALL_DIR}/.venv/bin/python -m uvicorn api_server:app --host ${BIND_ADDRESS} --port ${API_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

if [[ "${OPEN_UFW:-0}" == "1" ]] && command -v ufw >/dev/null 2>&1; then
	log "Opening firewall ports with ufw: ${CDP_PORT}, ${API_PORT}, ${VNC_PORT}, ${NOVNC_PORT}"
	ufw allow "${CDP_PORT}"/tcp || true
	ufw allow "${API_PORT}"/tcp || true
	ufw allow "${VNC_PORT}"/tcp || true
	ufw allow "${NOVNC_PORT}"/tcp || true
fi

log "Reloading systemd and starting services..."
systemctl daemon-reload
systemctl enable --now remote-xvfb.service
systemctl enable --now remote-wm.service
systemctl enable --now remote-chromium.service
systemctl enable --now remote-vnc.service
systemctl enable --now remote-novnc.service
systemctl enable --now remote-browser-api.service

log "Waiting for Chromium CDP endpoint..."
for i in $(seq 1 30); do
	if curl -fsS "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

log "Waiting for noVNC endpoint..."
for i in $(seq 1 30); do
	if curl -fsS "http://127.0.0.1:${NOVNC_PORT}/vnc.html" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

if command -v ss >/dev/null 2>&1; then
	for port in "${CDP_PORT}" "${API_PORT}" "${VNC_PORT}" "${NOVNC_PORT}"; do
		LISTEN_ROW="$(ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $4; exit}')"
		if [[ -n "${LISTEN_ROW}" && "${LISTEN_ROW}" == "127.0.0.1:${port}" ]]; then
			log "WARNING: service on port ${port} is listening on 127.0.0.1 only."
		fi
	done
fi

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
echo "VNC Endpoint:"
echo "  ${PUBLIC_HOST}:${VNC_PORT}"
echo "  Password: ${VNC_PASSWORD}"
echo
echo "noVNC URL (open in local browser):"
echo "  http://${PUBLIC_HOST}:${NOVNC_PORT}/vnc.html?host=${PUBLIC_HOST}&port=${NOVNC_PORT}"
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
