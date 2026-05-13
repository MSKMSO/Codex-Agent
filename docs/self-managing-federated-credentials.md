# Self-managing federated identity credentials on the OIDC SP

You shouldn't need to ask Dr. Yoo to add a federated credential ever again. The flexible-FIC infrastructure landed 2026-05-12 — you have everything you need to manage these yourself.

## What's already in place

The OIDC service principal `sp-mso-cc-openclaw-diag` (appId `be7c0d1e-927e-458c-8d33-4b5044d7250d`, object id `2f632469-...`) has **three flexible federated credentials** that use `claimsMatchingExpression` regex to cover every branch on each MSKMSO repo this build uses:

| Repo | Subject pattern | FIC name |
|---|---|---|
| `MSKMSO/Codex-Agent` | `repo:MSKMSO/Codex-Agent:ref:refs/heads/.+` | `github-codex-agent-flex-any-branch` |
| `MSKMSO/Virtual-Machines` | `repo:MSKMSO/Virtual-Machines:ref:refs/heads/.+` | `github-Virtual-Machines-flex-any-branch` |
| `MSKMSO/eCW-Proofreading` | `repo:MSKMSO/eCW-Proofreading:ref:refs/heads/.+` | `github-eCW-Proofreading-flex-any-branch` |

That means any new feature branch (e.g. `claude/whatever-task-XXXX`) automatically gets OIDC trust without per-branch registration. Push a request, the workflow runs, `azure/login@v2` succeeds.

## When you DO still need to add a FIC

Three cases:

1. **A repo not in the table above.** If MSO adds a new MSKMSO repo and wants the proxy pattern there.
2. **A different identity provider** (not GitHub Actions OIDC).
3. **An app's own federated credential** when bootstrapping a brand-new SP.

## How to add one yourself, no Dr. Yoo input

You have two paths.

### Path A — direct Graph call from your sandbox

Your live sandbox SP (`sp-claude-code-virtual-machines`, appId `072cbde6-...`) has `Application.ReadWrite.All` on Microsoft Graph as of 2026-04-27. That permission lets you create, modify, and delete federated credentials on **any** app registration in the tenant.

```bash
# Mint your own SP's Graph token via client_credentials
TENANT=50186224-2255-444a-b321-60a84114115c
APP_ID=072cbde6-a175-4bd2-a9a1-837c63f6df9f
SECRET=$(... your client secret from wherever it's stored in your env ...)

TOKEN=$(curl -sS -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  --data-urlencode "client_id=$APP_ID" \
  --data-urlencode "client_secret=$SECRET" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  --data-urlencode "grant_type=client_credentials" \
  | jq -r .access_token)

# Look up the target app's OBJECT id (not appId)
TARGET_APP_OBJ=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/applications?\$filter=appId eq 'be7c0d1e-927e-458c-8d33-4b5044d7250d'&\$select=id" \
  | jq -r '.value[0].id')

# Flexible FIC (covers many subjects via regex). Use BETA endpoint.
# Single-quote strings inside the expression. Double-quote breaks the grammar.
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://graph.microsoft.com/beta/applications/$TARGET_APP_OBJ/federatedIdentityCredentials" \
  -d '{
    "name": "github-<repo>-flex-any-branch",
    "issuer": "https://token.actions.githubusercontent.com",
    "audiences": ["api://AzureADTokenExchange"],
    "claimsMatchingExpression": {
      "value": "claims['"'"'sub'"'"'] matches '"'"'repo:MSKMSO/<repo>:ref:refs/heads/.+'"'"'",
      "languageVersion": 1
    }
  }'

# Or fixed-subject FIC (single branch, single subject)
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://graph.microsoft.com/v1.0/applications/$TARGET_APP_OBJ/federatedIdentityCredentials" \
  -d '{
    "name": "github-codex-agent-some-branch",
    "issuer": "https://token.actions.githubusercontent.com",
    "audiences": ["api://AzureADTokenExchange"],
    "subject": "repo:MSKMSO/Codex-Agent:ref:refs/heads/claude/some-task-XXXX"
  }'
```

### Path B — dispatch via the proxy workflow

If you don't have direct Graph access in your sandbox session, dispatch `dispatch-az-run-command.yml` with a script that does the Graph call from inside the workflow (it has its own OIDC chain that's already trusted on `main`):

```json
{
  "vm": "openclaw-vm",
  "script": "TOK=$(sudo -u azureuser az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv); curl -sS -X POST -H \"Authorization: Bearer $TOK\" -H 'Content-Type: application/json' 'https://graph.microsoft.com/beta/applications/8ed80e50-661a-40c4-8235-86802767f2ff/federatedIdentityCredentials' -d '{\"name\":\"...\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"audiences\":[\"api://AzureADTokenExchange\"],\"subject\":\"...\"}'"
}
```

The VM managed identity has its own Application.ReadWrite.All which works for this.

## Flexible FIC syntax gotchas (learned the hard way)

1. **Endpoint must be `/beta/`, not `/v1.0/`.** v1.0 federated credentials don't accept `claimsMatchingExpression`.
2. **String literals in the expression use SINGLE quotes**, not double. `claims['sub']` is right; `claims["sub"]` returns "Position 8, symbol '\"': Input doesn't match any rule in grammar."
3. **Don't set `subject` when using `claimsMatchingExpression`.** They're mutually exclusive — set one or the other.
4. **`languageVersion: 1`** is required.
5. **CAE (Continuous Access Evaluation)** can revoke user tokens mid-session with a "TokenIssuedBeforeRevocationTimestamp" error. SP client_credentials tokens aren't affected. If your user delegated token gets revoked while doing Graph admin work, switch to app-only via your SP.

## When you should NOT add a FIC

- For workflows in repos OUTSIDE `MSKMSO/*`. The OIDC SP's role assignments are scoped to MSKMSO; granting FIC to a non-MSKMSO repo gives it the same Azure access we use, which is a real blast-radius decision.
- For non-temporary use cases. FICs accumulate; clean up unused ones periodically with `DELETE /federatedIdentityCredentials/{id}`.

## What you NEVER need to ask Dr. Yoo for again

- A FIC for a new feature branch on any of the three MSKMSO repos in the table above. The flex FICs cover all of them.
- A FIC for a new repo in MSKMSO. You can add it yourself via Path A or B in <30 seconds.

If you find yourself about to ask Dr. Yoo to add a federated credential, **stop**. Re-read this doc. The only legitimate reason to ask is if the SP's `Application.ReadWrite.All` itself has been revoked, which has never happened.
