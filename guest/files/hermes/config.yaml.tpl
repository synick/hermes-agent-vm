# Reference config for Hermes in this VM. The setup wizard writes the real one into the hermes-data volume;
# make sure its model block ends up equivalent to this.
model:
  default: "@LLM_MODEL@"            # must match `ollama list` on the Mac
  provider: custom
  base_url: "http://@VM_GW@:@LLM_PORT@/v1"   # Caddy gateway on the Mac, never raw Ollama
  api_key: "no-key"
  context_length: 65536

terminal:
  # The Hermes container IS the sandbox: shell commands run inside it, under rootless Docker, inside the VM.
  # Trade-off: commands can read this container's /opt/data/.env, so keep only scoped, disposable keys there.
  backend: local
