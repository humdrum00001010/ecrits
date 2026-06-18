# ecrits Playwright e2e

Drives real Chromium against the **public sprite URL**
`https://ecrits-studio-v7zk.sprites.app/`.

Not `localhost:4002`. Not in-process. Not Wallaby. See
the private local assistant memory note `feedback-browser-persona-tests` for the
binding acceptance bar.

## Run

```bash
pnpm install
npx playwright install chromium
npx playwright install-deps chromium  # Linux only, first time

pnpm test              # headless, all browsers
pnpm test:headed       # eyeballs
pnpm test:trace        # always-on trace
pnpm report            # open last HTML report
```

## Config

| Env                 | Default                                          | Purpose                                                                |
| ------------------- | ------------------------------------------------ | ---------------------------------------------------------------------- |
| `E2E_BASE_URL`      | `https://ecrits-studio-v7zk.sprites.app`       | Override to point at a different sprite (or a tunneled local).         |
| `SPRITE_TOKEN`      | unset                                            | If the sprite URL is configured with `--auth token`, set this to the token. |
| `CI`                | unset                                            | `1` in CI: enables retries, narrower workers.                          |

## Test-only Elixir routes

The Phoenix app exposes two routes when
`Application.compile_env(:ecrits, :test_auth, false)` is `true`
(currently `true` in `:dev` and `:test`, `false` in `:prod`):

* `POST /test/personas/:persona/sign_in` — mints a fresh confirmed user
  via `Ecrits.PersonaFactory`, sets the session cookie, returns
  `{ ok: true, persona, user_id, email }`.
* `POST /test/reset` — runs `Ecrits.E2E.reset!/0`, which tears down
  the `e2e` matter scope.

In production both routes 404 (compile-time elision via `compile_env`).

## Scenarios

| File                | Status     | Covers                                                                 |
| ------------------- | ---------- | ---------------------------------------------------------------------- |
| `smoke.spec.ts`     | live       | Each persona signs in and reaches the home page over the public URL.   |

Wave 3C1 (Studio LV) inherits this harness and adds:

* briefing → grill → edit
* socket reconnect
* Cmd+K palette
* agent_supervised watcher

## Local office (libre) viewer suite

`playwright.local.config.ts` drives the **local desktop dev server**
(`localhost:4000`), not the sprite — the LibreOffice→WASM ("libre") viewer and
chat-rail only exist there. The dev server's `CrossOriginIsolationPlug` supplies
the COOP/COEP headers office WASM needs, and headless Chromium honours
`SharedArrayBuffer` under them, so the viewer boots under Playwright.

```bash
# deterministic (boots office WASM, renders docx/pptx, probes picture selection)
npx playwright test --config playwright.local.config.ts

# chat-rail e2e (real agent provider CLI + LLM — slow, gated)
RUN_AGENT=1 npx playwright test --config playwright.local.config.ts office-chat-rail
```

| File                       | Status      | Covers                                                                 |
| -------------------------- | ----------- | ---------------------------------------------------------------------- |
| `office-viewer.spec.ts`    | live        | docx + pptx render in the libre viewer; picture-selection probe.       |
| `office-chat-rail.spec.ts` | `RUN_AGENT` | chat-rail agent edits a docx open in the libre viewer (real provider). |

Fixtures (`fixtures/office/picture.{docx,pptx}`) are authored headlessly by the
office NIF — a docx with an inline picture, a pptx with a `GraphicObjectShape`.

**Known gap (documented via `test.fail`):** the office viewer renders inserted
pictures but its picker (`resolveRef`) does NOT resolve them as selectable
elements — a docx inline picture falls through to its paragraph, and pptx added
shapes resolve only to the slide's native placeholders. This is the office twin
of the HWP picture-selection fix (`hwpControlAtHit` → `getPageControlLayout`),
with no office/LOK equivalent yet. The two selection tests are expected failures
today; they flip to hard failures the day the office arm is fixed.
