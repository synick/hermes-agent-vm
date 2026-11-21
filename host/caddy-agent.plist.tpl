<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- KeepAlive retries until the VM network (and the gateway address Caddy binds to) exists. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{{CADDY_AGENT_LABEL}}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{{CADDY_BIN}}</string>
    <string>run</string>
    <string>--config</string>
    <string>{{CONFIG_DIR}}/Caddyfile</string>
    <string>--adapter</string>
    <string>caddyfile</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>20</integer>
  <key>StandardErrorPath</key>
  <string>{{LOG_DIR}}/hermes-vm-caddy.log</string>
</dict>
</plist>
