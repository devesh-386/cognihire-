# Ticket 9 — cloud VM (Ollama + face service)

One small always-on VM serves both the HR desktop app and the candidate web app,
so interviews work from anywhere, not just localhost.

## Steps

1. **Provision the VM.** Hetzner Cloud CX32 (2 vCPU / 8GB RAM), Ubuntu 24.04. 8GB is the
   floor for `qwen2.5:7b` running comfortably alongside the face service.
2. **Point a domain at it.** Any subdomain you own, A record → the VM's IP.
3. **SSH in and run the base setup:**
   ```bash
   scp cloud_vm_setup.sh root@<VM_IP>:
   ssh root@<VM_IP> 'bash cloud_vm_setup.sh'
   ```
   Installs Ollama, pulls `qwen2.5:7b`, sets up the firewall, installs nginx/certbot.
4. **Deploy the face service:**
   ```bash
   ssh root@<VM_IP>
   useradd -m -s /bin/bash cognihire
   mkdir -p /opt/cognihire && chown cognihire:cognihire /opt/cognihire
   su - cognihire
   git clone <this repo> /opt/cognihire/repo   # or scp service/ directly
   cp -r /opt/cognihire/repo/service /opt/cognihire/service
   cd /opt/cognihire/service
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   exit  # back to root
   ```
   Edit `ALLOWED_ORIGINS` in `face-service.service` to the real HR/candidate app
   origins once Ticket 13 has them, then:
   ```bash
   cp face-service.service /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now face-service
   ```
5. **Reverse proxy + TLS:**
   ```bash
   cp nginx-cognihire.conf /etc/nginx/sites-available/cognihire
   # edit YOUR_DOMAIN_HERE first
   ln -s /etc/nginx/sites-available/cognihire /etc/nginx/sites-enabled/
   nginx -t && systemctl reload nginx
   certbot --nginx -d <your-domain>
   ```
6. **Verify:**
   ```bash
   curl https://<your-domain>/ollama/api/tags
   curl https://<your-domain>/face/health   # or whatever health route main.py exposes
   ```
7. **Point the apps at it** — relaunch with:
   ```
   --dart-define=OLLAMA_BASE_URL=https://<your-domain>/ollama
   --dart-define=FACE_SERVICE_URL=https://<your-domain>/face
   ```

## Cost

Hetzner CX32 ≈ €13.10/mo (~$14). This is the only ongoing infra cost in the pivot —
Supabase (Ticket 8) is free tier.
