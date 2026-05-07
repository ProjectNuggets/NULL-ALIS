# S-Tier UI/UX Skills for Claude Code — Installation Guide

**Date:** May 2026  
**Context:** Spawning a dedicated Claude Code session for zaki-prod frontend work (React + TypeScript + Vite + Tailwind v4 + dark/light theme)

---

## Overview

This guide installs production-grade UI/UX skills that eliminate "AI slop" aesthetics and ship truly polished, distinctive design output. Each skill is verified to exist as of May 2026 and includes exact install commands.

---

## 1. Official Anthropic Skills (Pre-installed or Bundled)

### Frontend Design (Anthropic Official)
**Status:** Built-in plugin to Claude Code  
**Install:** Already available—no additional command needed  
**What it does:** Instructs Claude to think through design purpose, visual tone, constraints, and differentiation *before* writing code. Explicitly bans overused fonts (Inter, Roboto, Arial, Space Grotesk) and pushes for distinctive typography, color palettes, high-impact animations, and context-aware details.

**Why S-tier:**
- 277,000+ installs as of March 2026
- Forces deliberate aesthetic choices instead of statistical defaults
- Works seamlessly with Tailwind, React, and component libraries
- Eliminates "distributive convergence" (AI tendency to produce look-alike interfaces)

**Usage example:**
```
Build me a settings dashboard with a modern, bold aesthetic. Avoid purple gradients. 
Choose a distinctive serif or variable font. Use semantic spacing.
```

---

### Canvas Design (Built-in)
**Status:** Built-in to Claude  
**What it does:** Create beautiful visual art (.png, .pdf) using design philosophies  
**Use for:** Logo concepts, color palette visualization, mockup assets before handing to frontend

---

### Brand Guidelines (Built-in)
**Status:** Built-in to Claude  
**What it does:** Apply Anthropic's official brand colors and typography patterns  
**Useful for:** Learning what S-tier brand constraint looks like (reference, not direct usage for zaki-prod)

---

## 2. Community High-Tier Skills (GitHub-Hosted, Zero Cost)

### shadcn/ui Component Library Integration
**Repository:** `ui.shadcn.com/docs/skills`  
**Install:**
```bash
claude skills add ui.shadcn.com/docs/skills
# OR via GitHub:
claude skills add https://github.com/shadcn-ui/ui/tree/main/skills
```

**What it does:** Teaches Claude how to find, install, compose, and customize shadcn/ui components (built on Radix UI primitives + Tailwind). Project-aware context prevents hallucinated components.

**Why S-tier for zaki-prod:**
- Radix UI = battle-tested accessible primitives (ARIA, keyboard nav, focus management)
- Shadcn = copy-paste components you own and can customize
- Tailwind integration = seamless v4 configuration
- Prevents "reinventing the Button component"

---

### Tailwind v4 + Design System Skill
**Repository:** `secondsky/claude-skills` (Tailwind v4 + Shadcn bundle)  
**Install:**
```bash
claude skills add https://github.com/secondsky/claude-skills
```

**What it does:** Teaches Claude Tailwind v4 CSS-first configuration, semantic design tokens (OKLCH color space), dark mode with @custom-variant, and responsive design patterns.

**Why S-tier:**
- Covers Tailwind v4 specifics (not v3 documentation)
- Generates CVA-based component variants (classnames-based variant handling)
- Semantic tokens = color system that works in light/dark
- Implements proper dark mode toggle without utility duplication

**Key patterns it unlocks:**
- `@apply` refactoring to avoid utility bloat
- `@custom-variant` for theme-aware utilities
- Color scales via OKLCH (perceptually uniform)
- Spacing scale locks to 8px grid

---

### Accessibility (a11y) Audit Suite
**Repository:** `Community-Access/accessibility-agents`  
**Install:**
```bash
claude skills add https://github.com/Community-Access/accessibility-agents
```

**What it does:** Eleven specialist agents enforce WCAG 2.2 AA compliance. Covers keyboard nav, focus management, color contrast, ARIA patterns, skip links, motion reduction, alt text, captions.

**Why S-tier:**
- Prevents inaccessible code from being shipped
- WCAG 2.2 AA (not outdated 2.1)
- Checks form labels, error messaging, semantic HTML
- Color contrast audit (especially critical for dark/light themes)

**Triggered automatically when:** Adding forms, interactive components, or color-critical design

---

### Framer Motion Animation Skill
**Repository:** `Schoepplake/framer-motion-skill`  
**Install:**
```bash
claude skills add https://github.com/Schoepplake/framer-motion-skill
```

**What it does:** Teaches Claude Framer Motion patterns: AnimatePresence (mount/unmount), FLIP layout animations, drag interfaces, scroll-driven motion (useScroll, useTransform), and viewport triggers (useInView).

**Why S-tier for zaki-prod:**
- Micro-interactions feel native and performant
- Reduces imperative animation code
- Gesture helpers for drag/swipe UX
- Scroll-triggered animations (Obsidian-aesthetic scroll effects)

**Example unlocked:**
- Stagger list animations
- Shared element transitions between pages
- Drag-to-reorder interfaces
- Scroll parallax without janky performance

---

### Playwright Visual Regression Skill
**Repository:** `az9713/playwright-ui-testing`  
**Install:**
```bash
claude skills add https://github.com/az9713/playwright-ui-testing
```

**What it does:** 482+ test cases for visual regression, functional E2E tests, and UX design quality checks. Claude auto-writes & executes Playwright tests; catches visual diffs before deploy.

**Why S-tier:**
- Prevents pixel-level regressions in dark/light theme switching
- Catches animation jank, color shifts, spacing drift
- Disables animations in screenshots for stable baselines (`maxDiffPixelRatio: 0.01`)
- Integrates with CI/CD (run in PR checks)

**Workflow:**
1. Claude modifies a button component
2. Playwright skill auto-runs visual baseline capture
3. Any future change triggers diff test → prevents breaking changes

---

## 3. MCP Servers (Design Tools Integration)

### Figma MCP Server (Remote, Recommended)
**Setup:**
```bash
# Install Figma plugin in Claude Code (includes MCP config)
# Via CLI: fetch from https://help.figma.com/hc/en-us/articles/39888612464151
```

**What it does:**
- Read design context from Figma (components, variables, layout data)
- Generate code from selected frames
- Use Code Connect to keep designs ↔ code in sync
- Send live web interfaces back to Figma as editable layers

**Why S-tier:**
- **Selection-based workflow:** Select a frame in Figma → ask Claude to implement it → code stays aligned with design
- **Link-based workflow:** Paste Figma link in prompt → Claude fetches design context automatically
- Eliminates "screenshot to code" guesswork
- Bidirectional: code → Figma (inspect on canvas what Claude built)

**Setup resources:**
- [Figma MCP Setup Guide](https://help.figma.com/hc/en-us/articles/39888612464151-Claude-Code-and-Figma-Set-up-the-MCP-server)
- [Remote Server Installation](https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/)

---

### Storybook MCP (Optional: Component Documentation)
**What it does:** Sync component stories, variants, and documentation with Claude  
**Use when:** Documenting shadcn overrides or zaki-prod brand components  
**Install:** Check https://mcp.storybook.js.org for latest setup

---

## 4. System Prompt / CLAUDE.md Patterns for Design Work

Create a `.claude/DESIGN.md` or append to `CLAUDE.md`:

```markdown
# Design System — zaki-prod

## Visual Identity
- **Primary Font:** Geist (variable, sans-serif) — distinctive, modern, clean
- **Secondary Font:** Crimson Text (serif, accents) — elegant, blog-like, Obsidian-aesthetic
- **Avoid:** Inter, Roboto, Arial, system fonts (overused by AI)

## Color System (OKLCH — perceptually uniform)
### Light Mode
- Background: `oklch(98% 0.01 0)` (near-white with subtle warmth)
- Surface: `oklch(100% 0 0)` (pure white)
- Foreground: `oklch(15% 0.05 280)` (very dark purple-grey)
- Primary: `oklch(55% 0.15 280)` (purple, readable on light)
- Secondary: `oklch(65% 0.08 200)` (muted blue)

### Dark Mode
- Background: `oklch(12% 0.02 280)` (deep purple-black)
- Surface: `oklch(18% 0.03 280)` (slightly lighter)
- Foreground: `oklch(92% 0.01 0)` (off-white)
- Primary: `oklch(75% 0.15 280)` (bright purple)
- Secondary: `oklch(72% 0.10 200)` (bright blue)

## Spacing Scale (8px Grid)
- xs: 4px, sm: 8px, md: 16px, lg: 24px, xl: 32px, 2xl: 48px, 3xl: 64px

## Typography Scale
- h1: 36px, 1.2 line-height, font-weight 600 (Geist)
- h2: 28px, 1.3 line-height, font-weight 600
- h3: 22px, 1.4 line-height, font-weight 500
- body: 16px, 1.6 line-height, font-weight 400
- small: 14px, 1.5 line-height, font-weight 400
- code: 13px, Fira Code, monospace

## Dark Mode Strategy
- Use Tailwind `@custom-variant` for theme-aware utilities
- `@apply dark:bg-surface` for surface changes (not utility-stack duplication)
- Test all color contrast ratios (WCAG AA: 4.5:1 text, 3:1 UI components)

## Animation Patterns (Framer Motion)
- Page transitions: 200ms ease-in-out
- Hover states: 150ms cubic-bezier(0.2, 0, 0, 1)
- Drag interactions: velocity-based spring physics
- Scroll reveals: useInView with stagger 0.05s per item

## Component Conventions
- All buttons have explicit `aria-label` if icon-only
- Forms use React Hook Form + Zod validation
- Modals trap focus, close on Escape
- Lists implement virtual scrolling if >100 items

## Accessibility Checklist
- [ ] Color contrast ≥ 4.5:1 (text), ≥ 3:1 (UI)
- [ ] Keyboard nav without mouse (Tab, Shift+Tab, Enter, Escape)
- [ ] All images have alt text
- [ ] Focus indicators visible (not removed)
- [ ] Motion can be disabled (prefers-reduced-motion respected)
- [ ] Form fields properly labeled and grouped
- [ ] Error messages associated with inputs (aria-describedby)

## Do Not
- Gradient text over images (accessibility fail)
- Animations that loop infinitely without user control
- Color-only information conveyance (must have pattern/text)
- Empty buttons or links (must have accessible name)
- Disabled buttons without explanation
- Truncated text without title attribute

## Do
- Use semantic HTML (nav, main, section, article)
- Implement skip links if complex header
- Provide loading states, not spinners alone
- Use CSS Grid for complex layouts
- Implement proper focus management in modals
- Use design tokens for every color/spacing decision
```

Save this to `/Users/nova/Desktop/zaki-prod/.claude/DESIGN.md` before starting the UI session. Claude will auto-load it.

---

## 5. Installation Checklist for New Session

Before starting the dedicated UI session, run:

```bash
# 1. Install shadcn/ui skill
claude skills add https://github.com/shadcn-ui/ui/tree/main/skills

# 2. Install Tailwind v4 + design system
claude skills add https://github.com/secondsky/claude-skills

# 3. Install a11y audits
claude skills add https://github.com/Community-Access/accessibility-agents

# 4. Install Framer Motion
claude skills add https://github.com/Schoepplake/framer-motion-skill

# 5. Install Playwright visual regression
claude skills add https://github.com/az9713/playwright-ui-testing

# 6. Set up Figma MCP (via plugin)
# Follow: https://help.figma.com/hc/en-us/articles/39888612464151

# 7. Create or copy .claude/DESIGN.md (see section 4)

# 8. Verify all skills loaded
claude skills list
```

---

## 6. Recommended Workflow

**Phase 1: Design Foundation**
1. Open Figma link in Claude prompt (Figma MCP auto-loads design)
2. Ask: "Build a production Button component matching this Figma frame. Use shadcn Button (Radix) as base, customize with our design tokens."
3. Claude reads Figma context, uses shadcn skill, generates Tailwind-styled component

**Phase 2: Build & Test**
1. Claude writes component with TypeScript + variants (CVA)
2. Playwright skill auto-runs visual regression (baseline capture)
3. Accessibility skill audits: keyboard nav, color contrast, ARIA patterns
4. Framer Motion skill adds micro-interactions (hover, focus)

**Phase 3: Dark Mode & Polish**
1. CLAUDE.md color tokens guide semantic palette choices
2. Tailwind @custom-variant handles dark mode without duplication
3. Playwright tests both light/dark baselines
4. a11y suite rechecks contrast in both themes

**Phase 4: Deploy**
1. All visual regressions captured
2. E2E tests green
3. A11y checks pass
4. Figma stays in sync via Code Connect

---

## 7. Quick Reference: Top Skills Summary

| Skill | Install | Best For |
|-------|---------|----------|
| **Frontend Design** | Built-in | Aesthetic direction before code |
| **shadcn/ui** | GitHub (ui.shadcn.com) | Component primitivies + Radix a11y |
| **Tailwind v4** | GitHub (secondsky) | Design tokens, dark mode, responsive |
| **a11y Suite** | GitHub (Community-Access) | WCAG 2.2 AA audits, contrast checks |
| **Framer Motion** | GitHub (Schoepplake) | Micro-interactions, scroll, drag |
| **Playwright** | GitHub (az9713) | Visual regression, E2E, design QA |
| **Figma MCP** | Figma plugin | Design ↔ code sync, Code Connect |

---

## 8. Further Reading

- [Claude Cookbook: Prompting for Frontend Aesthetics](https://platform.claude.com/cookbook/coding-prompting-for-frontend-aesthetics)
- [Figma MCP Setup Guide](https://help.figma.com/hc/en-us/articles/39888612464151-Claude-Code-and-Figma-Set-up-the-MCP-server)
- [shadcn/ui Documentation](https://ui.shadcn.com)
- [Framer Motion Docs](https://www.framer.com/motion)
- [Tailwind v4 Docs](https://tailwindcss.com/docs)
- [WCAG 2.2 Accessibility Guidelines](https://www.w3.org/WAI/WCAG22/quickref)

---

**Last verified:** May 2026  
**For:** zaki-prod UI/UX work session
