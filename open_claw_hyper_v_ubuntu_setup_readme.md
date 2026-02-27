# OpenClaw Setup Guide (Ubuntu on Hyper-V + Docker)

This document describes the complete process followed to install, configure, and successfully run OpenClaw inside an Ubuntu virtual machine hosted on Hyper‑V, including resolving gateway, authentication, and UI access issues.

---

# 1. Environment Overview

**Host OS:** Windows
**Virtualization:** Hyper‑V
**Guest OS:** Ubuntu Server 24.04 LTS
**Container Runtime:** Docker + Docker Compose
**Application:** OpenClaw (local build)

Goal: Run OpenClaw safely inside a VM and access the Canvas UI from the host machine.

---

# 2. Create Ubuntu VM in Hyper‑V

1. Open **Hyper‑V Manager**
2. Create a new **Generation 2** VM
3. Attach Ubuntu Server ISO
4. Allocate:
   - 4 GB RAM minimum
   - 2+ CPUs recommended
   - 80 GB disk (dynamic is fine)
5. Disable Secure Boot if Ubuntu ISO fails to boot

If you see:

```
The signed image's hash is not allowed (DB)
```

Disable Secure Boot in VM settings.

---

# 3. Install Ubuntu Server

Follow installer prompts:

- Configure network (DHCP is fine)
- Use default LVM partitioning
- Create user and password
- Skip additional server snaps

After installation:

```bash
sudo apt update
sudo apt upgrade -y
```

---

# 4. Install Docker & Docker Compose

```bash
sudo apt install -y docker.io docker-compose-plugin
sudo usermod -aG docker $USER
newgrp docker
```

Verify:

```bash
docker --version
docker compose version
```

---

# 5. Clone OpenClaw Repository

```bash
git clone <REPOSITORY_URL>
cd openclaw
```

---

# 6. Prepare Required Directories

Create persistent directories for config and workspace:

```bash
mkdir -p $HOME/.openclaw/config
mkdir -p $HOME/.openclaw/workspace
chmod -R 777 $HOME/.openclaw
```

---

# 7. Create .env File

Generate a secure gateway token:

```bash
openssl rand -hex 32
```

Create `.env` in the project root:

```
OPENCLAW_CONFIG_DIR=/home/<user>/.openclaw/config
OPENCLAW_WORKSPACE_DIR=/home/<user>/.openclaw/workspace
OPENCLAW_GATEWAY_TOKEN=<YOUR_GENERATED_TOKEN>
```

---

# 8. Build and Start OpenClaw

Build locally:

```bash
docker compose up -d --build
```

Verify containers:

```bash
docker ps
```

---

# 9. Fix "Missing config" Error

If gateway logs show:

```
Missing config. Run `openclaw config`
```

Run configuration wizard:

```bash
docker compose run --rm openclaw-cli config
```

Set:

```
gateway.mode = local
```

Restart gateway:

```bash
docker compose restart
```

---

# 10. Fix Control UI Non‑Loopback Error

If logs show:

```
non-loopback Control UI requires gateway.controlUi.allowedOrigins
```

Set allowed origins:

```bash
docker compose run --rm openclaw-cli config set gateway.controlUi.allowedOrigins '["http://127.0.0.1:18789","http://<VM_IP>:18789"]'
docker compose restart
```

---

# 11. Verify Gateway Is Running

Logs should show:

```
listening on ws://0.0.0.0:18789
Browser control listening on http://127.0.0.1:18791/
```

Ports:

- 18789 → Gateway + Canvas
- 18790 → (if exposed)
- 18791 → Browser control (loopback only)

---

# 12. Access Canvas UI (Authentication Required)

Direct browser access returns:

```
{"error":"Unauthorized"}
```

The gateway requires:

```
Authorization: Bearer <OPENCLAW_GATEWAY_TOKEN>
```

Verification via curl:

```bash
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18789/__openclaw__/canvas/
```

---

# 13. Configure Nginx Reverse Proxy (Auto‑Inject Token)

Create directory:

```bash
mkdir ~/openclaw-nginx
cd ~/openclaw-nginx
```

Create `nginx.conf`:

```nginx
events {}

http {
    server {
        listen 8080;

        location / {
            proxy_pass http://<VM_IP>:18789;
            proxy_set_header Host $host;
            proxy_set_header Authorization "Bearer <OPENCLAW_GATEWAY_TOKEN>";
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
```

Run:

```bash
docker run -d \
  --name openclaw-nginx \
  -p 8080:8080 \
  -v $PWD/nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx
```

Open in browser:

```
http://<VM_IP>:8080/__openclaw__/canvas/
```

Canvas should load successfully.

---

# 14. Test Agent Execution

Run a simple test:

```bash
docker compose run --rm openclaw-cli agent "Create a file hello.txt in the workspace with content: Hello from OpenClaw"
```

Verify:

```bash
cat $HOME/.openclaw/workspace/hello.txt
```

If file exists → system is fully operational.

---

# 15. Final System Status

At this point:

✔ Ubuntu VM running in Hyper‑V  
✔ Docker installed  
✔ OpenClaw built locally  
✔ Gateway configured in local mode  
✔ Auth token working  
✔ Canvas accessible via Nginx proxy  
✔ Agent execution verified  

OpenClaw is now fully functional and ready for:

- Gmail integration
- Web scraping workflows
- Automated agents
- Cron‑based automation
- Skill integrations

---

# Security Notes

- Do NOT expose port 18789 directly to the internet.
- Keep OpenClaw behind VM firewall or SSH tunnel.
- Never commit your `.env` file.
- Use strong tokens.

---

# Next Steps

Recommended next actions:

1. Configure Gmail OAuth
2. Implement scraping workflow
3. Create automated email pipeline
4. Add cron scheduling

---

End of Setup Guide

