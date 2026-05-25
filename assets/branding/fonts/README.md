# Branding fonts (PRIVATE — do NOT make this repo public without removing)

## Thmanyah Font Family

Copyright © 2026, thmanyah Publishing and Distribution. Full license at
`THMANYAH-LICENSE.pdf` in this directory. Bundled with nullalis under
the license's "embed in applications and websites" clause.

### License-permitted use HERE
- Embedded in nullalis's `produce_document` tool to render branded PDFs,
  DOCX, PPTX, HTML, and landing pages for the agent's deliverables.
- Bundled into the nullalis runtime artifact (binary + container image)
  for self-hosted and SaaS deployments under thmanyah Publishing's
  ownership umbrella.

### License-prohibited
- Redistribute, share, upload, host, or make the font files available
  for download on any public website / server / file-sharing service.
- If this repo is ever opened to the public (open-source release), the
  font files MUST be removed from the public tree FIRST. The
  `produce_document` resolver already supports an operator-provided
  font directory override (`branding.font_dir` in config), so the
  open-source release path is: delete this directory + ship the
  resolver + ship a README pointing operators at the thmanyah download.

### Files
- `thmanyahsans/` — sans-serif body (5 weights: Light, Regular, Medium,
  Bold, Black) — OTF + WOFF2
- `thmanyahserifdisplay/` — serif display (5 weights)
- `thmanyahseriftext/` — serif body (5 weights)

### Contact
license queries: ask@thmanyah.com — https://thmanyah.com/
