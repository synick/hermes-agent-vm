<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{{PF_DAEMON_LABEL}}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{{PF_LOADER}}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>30</integer>
  <key>StandardErrorPath</key>
  <string>/var/log/hermes-vm-pf.log</string>
</dict>
</plist>
