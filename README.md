# Caffeine AI Skills

**Agent-readable skill files for building on the Caffeine AI.**

Structured, agent-readable skill files for every platform extension. Your AI reads the skill. It builds correctly. No hallucinations.

---

Every skill includes:

| Section             | Purpose                                                        |
| ------------------- | -------------------------------------------------------------- |
| **Frontmatter**     | YAML metadata: name, description, version, package compatibility |
| **Overview**        | One paragraph. What the component does.                        |
| **Backend**         | Motoko module API and usage examples (`mo:caffeineai-*`)       |
| **Frontend**        | React hooks and TypeScript API (`@caffeineai/*`)               |
| **Implementation**  | Tested, copy-paste-correct code blocks                         |

Skills may include backend only, frontend only, or both — depending on the component.

## Skills

All skills live in `skills/extension-*/SKILL.md`. Each skill is a self-contained markdown file with YAML frontmatter.

| Skill | Description |
| --- | --- |
| [authorization](skills/extension-authorization/SKILL.md) | Authorization system with role-based access control |
| [camera](skills/extension-camera/SKILL.md) | Web-camera support |
| [core-infrastructure](skills/extension-core-infrastructure/SKILL.md) | Core infrastructure providing backend connection configuration, storage client, and React app entry point |
| [email](skills/extension-email/SKILL.md) | Support for sending service/transactional emails |
| [email-calendar-events](skills/extension-email-calendar-events/SKILL.md) | Support for organising events/meetings and sending invitations by email |
| [email-marketing](skills/extension-email-marketing/SKILL.md) | Send personalised marketing emails to subscribers with an unsubscribe link |
| [email-raw](skills/extension-email-raw/SKILL.md) | Send an email with multiple to, cc and bcc addresses |
| [email-verification](skills/extension-email-verification/SKILL.md) | Support for sending a verification email with a link to prove email ownership |
| [http-outcalls](skills/extension-http-outcalls/SKILL.md) | HTTP outcalls performed by the backend canister |
| [invite-links](skills/extension-invite-links/SKILL.md) | Invite-link / RSVP based access for guest responses |
| [object-storage](skills/extension-object-storage/SKILL.md) | General file/object storage with browser-cached HTTP URL access |
| [qr-code](skills/extension-qr-code/SKILL.md) | QR code scanner using the camera |
| [stripe](skills/extension-stripe/SKILL.md) | Payment support based on Stripe, supporting credit cards and debit cards |
| [user-approval](skills/extension-user-approval/SKILL.md) | Approval-based user management |

## Usage

### Install via CLI

Works with any agent that supports skills (Claude Code, Cursor, Windsurf, Copilot, and more):

```
npx skills add caffeinelabs/skills
```

Browse available skills, pick your agent, and install. See [skills.sh](https://skills.sh) for details.

### Fetch a Single Skill

Fetch a single skill directly and place it wherever your agent reads instructions from:

```bash
curl -sL https://raw.githubusercontent.com/caffeinelabs/skills/main/skills/extension-authorization/SKILL.md
```

Replace `extension-authorization` with the skill directory name from the table above.

### Discover All Skills

List all available skills programmatically:

```bash
curl -s https://api.github.com/repos/caffeinelabs/skills/contents/skills | \
  jq -r '.[].name'
```

## Skill File Structure for Extensions

Each `SKILL.md` follows a consistent structure:

```yaml
---
name: extension-name
description: Short description of what the component does.
version: 0.1.1
compatibility:
  mops:
    caffeineai-component-name: "~0.1.0"
  npm:
    "@caffeineai/component-name": "~0.1.0"
---
```

- **name** — identifier used for discovery and package resolution
- **description** — one-line summary for agents to match user intent
- **version** — skill file version
- **compatibility** — exact mops and/or npm package versions the skill documents

Below the frontmatter, skills are organized into `# Backend` and `# Frontend` sections with module APIs, usage examples, and integration notes.

## Packages

Each extension might leverage reusable package in `packages/`:

```
packages/
  <name>/
    backend/        # Motoko package (mops.toml)
    frontend/       # TypeScript package (package.json)
```

- **Backend** packages are published to the [mops](https://mops.one) registry as `caffeineai-*`
- **Frontend** packages are published to GitHub Packages as `@caffeineai/*`

## License

Apache-2.0
