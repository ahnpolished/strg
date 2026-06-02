# strg — Design System

## Identity

**strg** strips the noise. You lifted. You wrote it down. Now it's digital. That's it.

Designed for the person who already decided. They don't need onboarding. They don't need encouragement. They need their numbers, fast.

---

## Aesthetic Direction

**Obsidian Glass** — Professional iOS glassmorphism on a near-black canvas.

Cold, deliberate, precise. Like the gym at 5am: no decoration, pure function, brutal clarity. The only warmth is the heat of iron — a single accent color: burnt orange, `#FF4B00`.

---

## Color System

| Token | Hex / Value | Usage |
|-------|-------------|-------|
| `background` | `#080808` | App fill |
| `surface.glass` | `.ultraThinMaterial` | Cards, loading panel |
| `surface.subtle` | `rgba(255,255,255,0.04)` | Nested surfaces |
| `accent` | `#FF4B00` | CTA, weight values, highlights |
| `accent.glow` | `#FF4B00` @ 15% opacity | Radial bloom behind capture button |
| `text.primary` | `#FFFFFF` | Exercise names, big numbers |
| `text.secondary` | `rgba(255,255,255,0.45)` | Labels, captions |
| `text.tertiary` | `rgba(255,255,255,0.25)` | Notes, hints |
| `border.glass` | `rgba(255,255,255,0.07)` | Card strokes |
| `border.strong` | `rgba(255,255,255,0.12)` | Capture button ring |

---

## Typography

All system fonts — no custom fonts needed. Weight and tracking do the work.

| Role | Spec | Usage |
|------|------|-------|
| App wordmark | `.system(28, .black)` + tracking 4 | `STRG` in header |
| Exercise name | `.system(17, .bold)` uppercase | Card headline |
| Big number | `.system(32, .black, rounded)` | Sets×reps value |
| Weight value | `.system(28, .black, rounded)` | Weight, accent colored |
| Section label | `.system(11, .semibold)` + tracking 2.5 uppercase | "WORKOUT EXTRACTED" |
| Micro label | `.system(9, .semibold)` + tracking 1.5 uppercase | "SETS × REPS", "WEIGHT" |
| Notes | `.system(13, .regular)` italic | Entry notes |
| Status | `.system(11, .semibold)` | Latency badge |

---

## Glassmorphism Spec

```swift
// Primary card surface
.background(.ultraThinMaterial)
.overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
.shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 8)

// Capture circle
Circle().fill(.ultraThinMaterial)
    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    .shadow(color: Color(hex: "FF4B00").opacity(0.15), radius: 30)

// Loading panel
RoundedRectangle(cornerRadius: 28).fill(.ultraThinMaterial)
    .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
```

---

## Screen States

### 1. Capture (idle)

```
┌─────────────────────────────┐
│  STRG                       │  ← wordmark, no nav chrome
│                             │
│                             │
│         ·  ·  ·             │  ← pulsing concentric rings (accent, fading)
│       ┌───────┐             │
│       │  [⬆] │             │  ← glass circle, camera icon
│       └───────┘             │
│                             │
│      SCAN WORKOUT           │  ← micro label, secondary color
│  Tap to analyze your page   │  ← hint text, tertiary
│                             │
│                             │
└─────────────────────────────┘
```

- Pulsing rings: two concentric circles, `accent @ 30%` → `0%`, `easeInOut 2.5s` `repeatForever`, second ring delayed 0.4s
- Camera button: 160pt circle, `.ultraThinMaterial`
- Background: radial accent glow from top, `0.08` opacity, `startRadius 0`, `endRadius 400`

### 2. Processing

```
┌─────────────────────────────┐
│  [dimmed capture view]      │
│                             │
│      ┌──────────────┐       │
│      │   ◌ (spin)  │       │  ← glass panel, 2pt arc spinner, accent
│      │  READING     │       │
│      │  WORKOUT     │       │
│      └──────────────┘       │
│                             │
└─────────────────────────────┘
```

- Overlay: `black @ 0.65` blur backdrop
- Spinner: 64pt circle track `white @ 0.1` + 70% arc `accent`, `lineCap .round`, `1s linear repeat`
- Label: `READING WORKOUT` micro label style

### 3. Results

```
┌─────────────────────────────┐
│  STRG                 7.1s● │  ← header + latency badge
│                             │
│  WORKOUT EXTRACTED  3 EXER  │  ← section meta
│                             │
│  ┌─────────────────────┐    │
│  │ BENCH PRESS   05.02 │    │  glass card (staggered slide-up)
│  │ ─────────────────── │    │
│  │ SETS×REPS   WEIGHT  │    │
│  │   4×8      135 LBS  │    │
│  └─────────────────────┘    │
│  ┌─────────────────────┐    │
│  │ SQUAT               │    │
│  │   3×5      225 LBS  │    │
│  └─────────────────────┘    │
│                             │
│  [■ SCAN ANOTHER ■]         │  ← full-width accent button
└─────────────────────────────┘
```

- Cards: staggered appear, `0.08s` delay per card, `.spring(response: 0.5, dampingFraction: 0.8)`
- Weight value: `accent` color
- No weight → `—` (tertiary color)
- "Scan Another" button: solid `accent` fill, white inner gradient shimmer, `accent @ 40%` drop shadow

---

## EntryCard Anatomy

```
┌──────────────────────────────────┐
│  EXERCISE NAME          date     │  ← bold 17pt + right-aligned date caption
│  ─────────────────────────────── │  ← 0.5pt separator, white @ 6%
│                                  │
│  SETS × REPS              WEIGHT │  ← 9pt tracking micro labels
│     4×8                 135 LBS  │  ← 32pt black rounded / 28pt black rounded accent
│                                  │
│  "felt strong, PR next week"     │  ← italic notes, 13pt, tertiary (only if present)
└──────────────────────────────────┘
```

---

## Configuration (API URL hidden from UI)

Server URL and API key are resolved at build time from `Info.plist` substitution variables:

| Info.plist key | Build setting | Fallback |
|----------------|---------------|----------|
| `STRG_SERVER_URL` | `$(STRG_SERVER_URL)` | `http://localhost:8000` |
| `STRG_API_KEY` | `$(STRG_API_KEY)` | `""` |

Set in `xcconfig` or Xcode project build settings. **Never exposed in UI.**

`AppConfig.swift` reads these at startup and injects into `StrgAPIClient.init()`.

---

## Anti-patterns (never do)

- No server URL or API key text fields in any view
- No skeleton loaders (show nothing until result is ready)
- No onboarding flow
- No progress percentage (we don't know when model finishes)
- No success toast / confetti
- No color other than the defined palette
