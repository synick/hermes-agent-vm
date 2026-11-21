# Hermes Agent - runs under ROOTLESS Docker as the 'hermes' user inside the hardened VM.
# Layers: Mac pf  ->  VMware VM  ->  rootless Docker (uid-remapped)  ->  this locked-down container.
name: hermes

services:
  hermes:
    # Pinned by digest at build time (50-hermes.sh). Re-pin deliberately when you upgrade.
    image: @HERMES_IMAGE@
    container_name: hermes
    command: gateway run
    restart: unless-stopped

    volumes:
      - hermes-data:/opt/data          # config.yaml, .env, memory, sessions, skills

    tmpfs:
      - /tmp:size=1g,mode=1777
    shm_size: 1g                       # headroom for the browser tool

    # Least privilege. The image's init needs these few to set up and drop to its runtime user;
    # try removing them one at a time once it's running cleanly.
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID, KILL]
    security_opt:
      - no-new-privileges:true

    pids_limit: 512
    mem_limit: @MEM_LIMIT@     # the VM's memory minus 1 GB for Ubuntu; kept in step by hermes-vm.sh start
    cpus: @CPU_LIMIT@

    # No published ports by default. Hermes talks OUT to the Ollama gateway and (if you enable one) a
    # messaging platform; nothing needs to talk IN. For the dashboard, uncomment both blocks below and
    # reach it from the Mac with:  ./hermes-vm.sh ssh -L 9119:127.0.0.1:9119
    # ports:
    #   - "127.0.0.1:9119:9119"
    # environment:
    #   HERMES_DASHBOARD: "1"

volumes:
  hermes-data:
