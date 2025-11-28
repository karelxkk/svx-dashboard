# Installation Guide for svx-dashboard

This document describes installation using the official `.deb` package as well
as integration with SvxLink and supported web servers.

The `.deb` package installs:

- static web UI: `/usr/share/svx-dashboard/html/`
- SSE backend (systemd service): `svx-sse.service`
- ELB backend (systemd service): `elb-daemon.service`
- history rotation timer: `svx-history-rotate.timer`
- SVXLink event scripts under `/etc/svxlink/events.d/`
- Apache and Nginx configuration snippets
- tmpfiles rules for `/run/svxlink/`

---

## 1. Install the .deb package

```bash
sudo dpkg -i svx-dashboard_*.deb
sudo apt-get -f install
```

The installer places all dashboard components under `/usr/share/svx-dashboard/`
and registers systemd services.

---

## 2. Enable and start backend services

```bash
sudo systemd-tmpfiles --create
sudo systemctl enable --now svx-sse.service svx-history-rotate.timer elb-daemon.service
```

### Services installed

| Service                    | Function                                      |
|----------------------------|-----------------------------------------------|
| `svx-sse.service`          | SSE backend streaming live events/status      |
| `elb-daemon.service`       | ELB backend for link/status handling          |
| `svx-history-rotate.timer` | Rotation of `/run/svxlink/history.csv`        |

Check status:

```bash
systemctl status svx-sse.service
systemctl status elb-daemon.service
systemctl status svx-history-rotate.timer
```

---

## 3. Web server configuration

### 3.1 Apache HTTPD

A configuration snippet is installed at:

```
/etc/apache2/conf-available/svx-dashboard.conf
```

Enable it:

```bash
sudo a2enconf svx-dashboard
sudo a2enmod alias proxy proxy_http headers
sudo apache2ctl -t && sudo systemctl reload apache2
```

After that the dashboard is available at:

- Web UI: `http://<server>/svx/`
- SSE stream: `http://<server>/svx/sse`

---

### 3.2 Nginx

A snippet is installed at:

```
/etc/nginx/snippets/svx-dashboard.locations
```

To activate it, include it in a server block, for example:

```bash
sudo sh -c 'echo "include /etc/nginx/snippets/svx-dashboard.locations;" >> /etc/nginx/sites-available/default'
sudo nginx -t && sudo systemctl reload nginx
```

After reload:

- Web UI: `http://<server>/svx/`
- SSE stream: `http://<server>/svx/sse`

---

## 4. SvxLink integration

The dashboard requires runtime data from SvxLink (status, states, events).

### 4.1 Configure `/etc/svxlink/svxlink.conf`

Ensure the global event handler is enabled:

```ini
[GLOBAL]
EVENT_HANDLER=/etc/svxlink/events.tcl
```

The package provides event scripts:

```
/etc/svxlink/events.tcl
/etc/svxlink/events.d/svx_backend.tcl
/etc/svxlink/events.d/svx_serial.tcl
/etc/svxlink/events.d/svx_usrp.tcl
/etc/svxlink/events.d/EchoLink.tcl
```

These scripts generate:

- `/run/svxlink/status.json` (live status)
- `/run/svxlink/history.csv` (session history)

The files are created via tmpfiles:

```bash
sudo systemd-tmpfiles --create
```

---

## 5. SvxReflector integration (optional)

If you use SvxReflector, enable its HTTP server in
`/etc/svxlink/svxreflector.conf`:

```ini
HTTP_SRV_PORT=8880
```

This allows reflector events and TG information to appear in the dashboard.

---

## 6. File locations

| Path                                       | Purpose                            |
|--------------------------------------------|------------------------------------|
| `/usr/share/svx-dashboard/html/`           | Dashboard web UI                   |
| `/usr/lib/svx-dashboard/svx_sse.py`        | SSE backend                        |
| `/usr/lib/svx-dashboard/elb_daemon.tcl`    | ELB backend                        |
| `/usr/lib/svx-dashboard/svx_history_rotate.sh` | History rotation helper       |
| `/run/svxlink/status.json`                | Runtime status JSON                |
| `/run/svxlink/history.csv`                | Talkgroup/session history          |
| `/etc/apache2/conf-available/svx-dashboard.conf` | Apache configuration snippet |
| `/etc/nginx/snippets/svx-dashboard.locations`    | Nginx snippet                 |

---

## 7. Verification

Check the HTTP endpoint:

```bash
curl -I http://127.0.0.1/svx/
```

Check SSE stream:

```bash
curl -iN http://127.0.0.1/svx/sse | head -n5
```

You should see HTTP 200 and SSE-style lines.

---

## 8. Troubleshooting

### Dashboard not visible (404)

- Apache/Nginx snippet not enabled or not included in any vhost.
- URL path `/svx/` not matched by your server configuration.

### SSE stream empty or failing

- `svx-sse.service` not running:
  ```bash
  systemctl status svx-sse.service
  ```
- firewall or reverse proxy blocking `/svx/sse`.

### ELB not reporting

Check logs:

```bash
journalctl -u elb-daemon.service
```

### Missing `history.csv` or `status.json`

Run:

```bash
sudo systemd-tmpfiles --create
```

and verify directory permissions for `/run/svxlink`.

---

End of document.
