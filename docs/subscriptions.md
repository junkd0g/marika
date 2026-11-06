# Subscriptions: how they work here, and the rules

Last checked 5 November 2026. These terms have changed before, so check them again before shipping.

## How Marika uses a plan

Marika never signs anyone in and never sees a token. It starts the official CLI, and the CLI uses
whatever account the user signed in to with `claude auth login` or `codex login`. The sign-in button
opens that official command in Terminal. Codex may come from a separate install or from inside the
ChatGPT desktop app, which ships the same CLI.

Marika must keep these properties:

- Run the official `claude` binary unmodified. Never bundle a patched copy.
- Never read, store or forward Claude credentials. That includes `~/.claude` and the Keychain item
  the CLI uses.
- Never call Anthropic's API with a subscription token directly.
- Never pass `--bare`. It turns off subscription login.

## What Anthropic's documentation says

From [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance):

- Third-party developers may not offer Claude.ai login in their own applications, or route requests
  through Free, Pro, Max or Ultra credentials on behalf of their users.
- Developers may not collect, store or intermediate Claude.ai credentials or session tokens.
- This does not prevent an end user from signing in to the unmodified Claude Code binary with their
  own subscription.
- Products that run Claude Code need the Commercial Terms, must not modify the binary, and must not
  remove any sign-in method.
- Products **may not pay for, resell or intermediate** Claude usage. Each end user authenticates with
  their own key, plan or cloud credential, and is billed directly.
- You can say in plain text that your product runs Claude Code, but its names and logos can't be part
  of your product name or logo, or imply that Anthropic endorses you.

The [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) adds that, unless
previously approved, third-party developers may not offer claude.ai login or rate limits for their
products, and it sets naming rules. "Claude Agent" is the preferred label in menus.

The [support article](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
says the Agent SDK and `claude -p` still draw from subscription limits, and that previously announced
changes to this were paused on 15 June 2026.

**Reading these together:** one person running Marika with their own plan fits the allowance for
signing in to the unmodified binary. Selling Marika as a product that relies on customers' Claude
plans is closer to the line, because the SDK page says "offer", and the mechanics are the same either
way. Get written confirmation from Anthropic before selling it:
[contact sales](https://www.anthropic.com/contact-sales).

## Charging for Marika

- **Allowed by these terms:** charging for Marika itself, as long as each customer brings their own
  Claude plan, API key or cloud credential.
- **Not allowed:** a Marika subscription that includes Claude usage on your account or on subscription
  credentials. Reselling usage would need a different arrangement with Anthropic.

## Risks to watch

1. **The control protocol isn't a public API for other languages.** Marika speaks the stream-json
   control protocol that the official SDKs use. The docs point other languages at `claude -p`, which
   can't do live approvals. A CLI update could change it. The fixtures and live tests exist to catch
   this quickly.
2. **`-p` will default to `--bare`.** The docs say so, and bare mode ignores subscription logins.
   Marika launches without `-p`, as the SDK does in streaming mode, so it should not be affected.
3. **Plan terms can change.** Anthropic announced and then paused changes to SDK usage in 2026, and
   reserves the right to enforce these rules without notice. Keep API key billing working as the
   fallback.
4. **Usage limits assume ordinary individual use.** Heavy parallel agents could hit limits sooner.

## Codex

Marika talks to `codex app-server`, the interface OpenAI describes in
[Unlocking the Codex harness](https://openai.com/index/unlocking-the-codex-harness), and the one the
ChatGPT desktop app itself uses. Sign-in is through `codex login`. OpenAI's
[app-server docs](https://learn.chatgpt.com/docs/app-server) ask teams building enterprise integrations
to contact them about a known-clients list. The server is marked experimental, and this version is an
alpha, so expect protocol changes.

I did not find an explicit statement on whether third-party clients may use ChatGPT plan sign-in this
way, so confirm that with OpenAI before selling it too.
