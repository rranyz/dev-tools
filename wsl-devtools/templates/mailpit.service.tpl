# Managed by wsl-devtools: created {{CREATED}} by modules/install-mailpit.sh (Mailpit {{VERSION}})
# Remove with: sudo systemctl disable --now mailpit
#              sudo rm /etc/systemd/system/mailpit.service && sudo systemctl daemon-reload
[Unit]
Description=Mailpit email testing server (local only, wsl-devtools)
Documentation=https://mailpit.axllent.org/
After=network.target

[Service]
Type=simple
# SMTP and the web UI listen on localhost only. Messages are kept in the state directory.
ExecStart={{BINARY}} --smtp {{SMTP_ADDRESS}} --listen {{UI_ADDRESS}} --database /var/lib/mailpit/mailpit.db --disable-version-check
# Runs as a temporary system user created by systemd, not as root.
DynamicUser=yes
StateDirectory=mailpit
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
