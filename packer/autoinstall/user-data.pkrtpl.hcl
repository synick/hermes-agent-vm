#cloud-config
autoinstall:
  version: 1
  locale: en_AU.UTF-8
  keyboard:
    layout: us
  timezone: ${timezone}

  # Minimal server image = fewer packages = smaller attack surface.
  source:
    id: ubuntu-server-minimal

  identity:
    hostname: ${hostname}
    username: ${admin_username}
    password: "${admin_password_hash}"

  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - "${build_public_key}"   # throwaway build key; replaced with your real key at the end of the build

  # DHCP for the address only; public resolvers instead of the host's DNS forwarder (the host is firewalled off).
  network:
    version: 2
    ethernets:
      primary:
        match:
          name: "en*"
        dhcp4: true
        dhcp4-overrides:
          use-dns: false
        dhcp6: false
        accept-ra: false
        link-local: []
        nameservers:
          addresses: [${join(", ", dns_servers)}]

  storage:
    layout:
      name: lvm
      sizing-policy: all

  packages:
    - open-vm-tools

  updates: security
  shutdown: reboot
