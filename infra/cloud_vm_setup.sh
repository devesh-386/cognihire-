#!/usr/bin/env bash
# Ticket 9 — provisions the cloud VM that serves Ollama (qwen2.5:7b) and the
# face-verification service to both the HR desktop app and the candidate web
# app. Run as root on a fresh Ubuntu 24.04 box (e.g. Hetzner CX32, 8GB RAM).
set -euo pipefail

echo "== updating base system =="
apt-get update -y
apt-get upgrade -y
apt-get install -y curl git nginx certbot python3-certbot-nginx ufw python3-pip python3-venv

echo "== firewall: only SSH, HTTP, HTTPS =="
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "== installing Ollama =="
curl -fsSL https://ollama.com/install.sh | sh
systemctl enable ollama
systemctl start ollama
ollama pull qwen2.5:7b

echo "== Ollama installed. Next steps (manual, see infra/README.md): =="
echo "  1. Deploy service/ (FastAPI face service) to this box, run it on 127.0.0.1:8000"
echo "     behind systemd (see infra/face-service.service template)."
echo "  2. Point a domain's A record at this VM's IP."
echo "  3. Run: certbot --nginx -d <your-domain>"
echo "  4. Copy infra/nginx-cognihire.conf to /etc/nginx/sites-available/, symlink"
echo "     into sites-enabled, nginx -t && systemctl reload nginx."
echo "  5. Relaunch the apps with:"
echo "       --dart-define=OLLAMA_BASE_URL=https://<your-domain>/ollama"
echo "       --dart-define=FACE_SERVICE_URL=https://<your-domain>/face"
