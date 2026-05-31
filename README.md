# Jarvis Network

**Open-source AI infrastructure for businesses, communities, and individuals.**  
Locally deployable, community-owned, and built for anyone who wants private, sovereign control over their own AI environment.

---

## What is Jarvis Network?

Jarvis Network is a decentralized AI infrastructure platform built under the GNU General Public License v3.0. It provides the secure backbone required to run private AI models on community-owned hardware, completely independent of centralized cloud providers.

The goal is simple: any business, organization, community, or individual should be able to deploy a sovereign, private AI environment using open, replicable blueprints. Whether you are a small business owner, a developer, a researcher, or someone who simply wants to understand and control the technology they use, this project is built for you. No vendor lock-in, no unpredictable API costs, no third-party visibility into your data.

---

## Why it exists

Small businesses are being pushed toward AI tools they cannot audit, cannot afford long-term, and cannot trust with sensitive data. Centralized AI providers create systemic risk: prompt injection vulnerabilities, unilateral changes to terms of service, and pricing structures that price out the organizations that need these tools most.

Jarvis Network is built as the alternative. The infrastructure is designed to be replicated by anyone, audited by anyone, and owned by the community that deploys it.

---

## Core principles

- **Digital Sovereignty** — communities own their infrastructure and their data
- **Security-First** — zero-trust architecture, encrypted mesh networking, no third-party metadata exposure
- **Accessibility** — designed to be operable by non-technical users, not just engineers
- **Replicability** — every component is documented and deployable by any organization, anywhere

---

## Tech stack

| Layer | Technology |
|---|---|
| Mesh Networking | WireGuard / Headscale |
| Orchestration | Kubernetes (k3s) |
| Node Provisioning | Cloud-init |
| Inference | Ollama / vLLM (Mistral 7B, LLaMA 3.1 8B) |
| Speech-to-Text | faster-whisper |
| Text-to-Speech | Kokoro TTS |
| Pipeline | Pipecat |
| Storage | Longhorn CSI |
| Security | Cilium (mTLS), Falco, Teleport |
| Infrastructure | Vultr (VKE, bare metal, VPS) |

---

## Current status

Jarvis Network is in **Phase 1: Infrastructure Foundation**.

Active components:
- Headscale VPN coordination server operational with TLS
- Bare-metal node connected to mesh network
- Cloud-init automation for node provisioning
- Kubernetes cluster architecture in progress

Phase 1 is focused on building the secure, automated backbone the platform depends on. Deployment guides and replication documentation will be published upon Phase 1 completion.

---

## Documentation

- [Technical Overview](./TECHNICAL_OVERVIEW.md) — Architecture, current infrastructure state, hardware reference, and deployment roadmap.

---

## License

GNU General Public License v3.0. See [LICENSE](./LICENSE) for details.

---

## Contributing

Contribution guidelines and a Contributor License Agreement will be published alongside the first stable release. If you are interested in contributing or deploying this infrastructure for your own community, open an issue and start a conversation.

---

## Organization

Jarvis Network is an independent, community-driven project. Organizational details will be published as the project structure is finalized.
