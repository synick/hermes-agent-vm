// hermes-vm: Ubuntu Server LTS (arm64) on VMware Fusion, built unattended and hardened for Hermes Agent.
// Driven by ../hermes-vm.sh, which generates the -var-file and supplies secrets from the macOS Keychain.
//
// Build-time credentials follow the pattern used by github.com/konstruktoid/hardened-images:
//  - Packer connects with a throwaway SSH key made for this build only; the finalise step replaces it with
//    your real public key, and hermes-vm.sh deletes the throwaway key from the Mac afterwards.
//  - The sudo password travels in Packer's environment-variable file, never on a command line, and sudo is
//    told exactly which variables to keep (it drops SUDO_PASSWORD before the script runs).
//  - Nothing needs the password to shut down: the last step schedules the poweroff as root.

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    vmware = {
      source  = "github.com/vmware/vmware"
      version = "~> 2"
    }
  }
}

locals {
  user_data = templatefile("${path.root}/autoinstall/user-data.pkrtpl.hcl", {
    hostname            = lower(var.vm_name) // Ubuntu hostnames must be lowercase
    admin_username      = var.admin_username
    admin_password_hash = var.admin_password_hash
    build_public_key    = trimspace(file(var.build_ssh_public_key_file))
    timezone            = var.timezone
    dns_servers         = var.dns_servers
  })

  // Works with both classic sudo and sudo-rs (Ubuntu 26.04's default), which doesn't support `sudo -E`.
  preserved_vars = "ADMIN_USER,VM_GW,LLM_PORT,LLM_MODEL,HERMES_TAG,DNS_SERVERS"
  sudo_exec      = ". {{ .EnvVarFile }}; echo \"$SUDO_PASSWORD\" | sudo -S --preserve-env=${local.preserved_vars} bash -euo pipefail '{{ .Path }}'"

  build_env = [
    "SUDO_PASSWORD=${var.admin_password}",
    "ADMIN_USER=${var.admin_username}",
    "VM_GW=${var.vm_gw}",
    "LLM_PORT=${var.llm_port}",
    "LLM_MODEL=${var.llm_model}",
    "HERMES_TAG=${var.hermes_image_tag}",
    "DNS_SERVERS=${join(" ", var.dns_servers)}",
  ]
}

source "vmware-iso" "hermes" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type        = "arm-ubuntu-64"
  firmware             = "efi"
  disk_adapter_type    = "nvme"
  network_adapter_type = "vmxnet3"

  cpus      = var.cpus
  memory    = var.memory_mb
  disk_size = var.disk_size_mb
  network   = var.fusion_network
  headless  = var.headless

  vnc_bind_address = "127.0.0.1"
  vnc_port_min     = var.vnc_port_min
  vnc_port_max     = var.vnc_port_max

  // Autoinstall answers on a NoCloud "cidata" CD: no HTTP server, nothing exposed on the Mac.
  cd_content = {
    "user-data" = local.user_data
    "meta-data" = ""
  }
  cd_label = "cidata"

  // Boot from the GRUB command line rather than editing the menu entry, so it doesn't depend on the menu's layout.
  // "autoinstall" makes Subiquity use the cidata CD without asking; it must come before "---".
  boot_wait = var.boot_wait
  boot_command = [
    "c<wait3>",
    "linux /casper/vmlinuz autoinstall ---<enter><wait3>",
    "initrd /casper/initrd<enter><wait5>",
    "boot<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = var.admin_username
  ssh_private_key_file   = var.build_ssh_private_key_file // throwaway, this build only
  ssh_timeout            = "60m"
  ssh_handshake_attempts = 200

  // The final provisioner schedules the poweroff as root, so no password is needed here.
  shutdown_command = "true"
  shutdown_timeout = "10m"

  // VMware isolation: no shared folders, clipboard, drag-and-drop, device tampering or host-info leakage.
  // (VNC stays on during the build because Packer types the boot command through it; hermes-vm.sh turns it off.)
  vmx_data = {
    "isolation.tools.hgfs.disable"         = "TRUE"
    "isolation.tools.copy.disable"         = "TRUE"
    "isolation.tools.paste.disable"        = "TRUE"
    "isolation.tools.dnd.disable"          = "TRUE"
    "isolation.tools.diskWiper.disable"    = "TRUE"
    "isolation.tools.diskShrink.disable"   = "TRUE"
    "isolation.device.connectable.disable" = "TRUE"
    "isolation.device.edit.disable"        = "TRUE"
    "sharedFolder.maxNum"                  = "0"
    "tools.guestlib.enableHostInfo"        = "FALSE"
    "tools.setInfo.sizeLimit"              = "1048576"
  }
}

// Packer does only the base install: Ubuntu (autoinstall), your SSH key, then power off. Packer compacts the disk.
// Everything else (updates, hardening, Docker, Hermes) is `hermes-vm.sh provision`: separate, resumable steps over
// SSH, so a late failure doesn't mean reinstalling Ubuntu.
build {
  sources = ["source.vmware-iso.hermes"]

  // Your real public key; the step below installs it in place of the throwaway build key.
  provisioner "file" {
    content     = "${trimspace(file(pathexpand(var.ssh_public_key_file)))}\n"
    destination = "/var/tmp/hermes-admin-key.pub"
  }

  // As root: swap the throwaway build key for your real one, then power off (shutdown_command is just `true`).
  provisioner "shell" {
    execute_command  = local.sudo_exec
    environment_vars = local.build_env
    use_env_var_file = true
    remote_folder    = "/var/tmp"
    inline = [
      "install -d -m 0700 -o \"$ADMIN_USER\" -g \"$ADMIN_USER\" \"/home/$ADMIN_USER/.ssh\"",
      "install -m 0600 -o \"$ADMIN_USER\" -g \"$ADMIN_USER\" /var/tmp/hermes-admin-key.pub \"/home/$ADMIN_USER/.ssh/authorized_keys\"",
      "rm -f /var/tmp/hermes-admin-key.pub",
      "systemd-run --collect --unit=packer-poweroff --on-active=10 systemctl poweroff",
    ]
    expect_disconnect = true
  }
}
