#!/bin/bash
#
# Tier-2 wiring for Codex Agent (cootr / openclaw-codex) — gives the
# bot access to Dr. Yoo's professional identifiers from SDN-YooVault
# via a workspace policy file regenerated on each service restart.
#
# What this installs:
#   1. /home/azureuser/.openclaw-codex-fetch-identifiers.sh — a fetcher
#      that calls `az keyvault secret show ... dr-yoo-identifiers` and
#      writes a markdown identifier block into the Codex workspace dir.
#   2. ExecStartPre= line in openclaw-codex.service so the fetcher
#      runs before each service start.
#   3. Initial workspace file:
#        ~/.openclaw-codex/workspace-codex/DR_YOO_IDENTIFIERS.md
#      Codex's bootstrap reads workspace-codex/* on each session start,
#      so the identifiers become available to all of Codex's chats.
#
# Idempotent: re-running is safe. ExecStartPre is only added once.
# Marker: DR_YOO_IDENTIFIERS_V2_VAULT (matches the Python bots).

set -e

WORKSPACE=/home/azureuser/.openclaw-codex/workspace-codex
OUT=$WORKSPACE/DR_YOO_IDENTIFIERS.md
FETCH=/home/azureuser/.openclaw-codex-fetch-identifiers.sh
SYS=/etc/systemd/system/openclaw-codex.service

if [ ! -d "$WORKSPACE" ]; then
  echo "ERROR: $WORKSPACE not found — is Codex actually installed here?" >&2
  exit 1
fi
if [ ! -f "$SYS" ]; then
  echo "ERROR: $SYS not found" >&2
  exit 1
fi

# --- write fetcher ---------------------------------------------------------
cat > "$FETCH" <<'FETCH_EOF'
#!/bin/bash
# Auto-managed. Tier-2 vault fetch for Codex Agent. Re-run via
# `systemctl restart openclaw-codex`. Marker: DR_YOO_IDENTIFIERS_V2_VAULT.
set -e
WORKSPACE=/home/azureuser/.openclaw-codex/workspace-codex
OUT=$WORKSPACE/DR_YOO_IDENTIFIERS.md
mkdir -p "$WORKSPACE"
az login --identity --only-show-errors >/dev/null 2>&1 || true
S=$(az keyvault secret show --vault-name SDN-YooVault --name dr-yoo-identifiers --query value -o tsv 2>/dev/null || true)
if [ -z "$S" ]; then
  echo "[dr-yoo-identifiers-fetch] WARN: vault unreachable; leaving previous $OUT" >&2
  exit 0
fi
S="$S" python3 - <<'PYEOF'
import json, os
d = json.loads(os.environ["S"])
i = d.get("identity", {})
p = d.get("professional", {})
a = d.get("addresses", {})
pr = a.get("primary_practice", {})
ma = a.get("mailing", {})
c = d.get("contact", {})
f = d.get("affiliations", {})
md = (
    "# DR_YOO_IDENTIFIERS_V2_VAULT\n\n"
    "Dr. Yoo's professional identifiers — auto-fetched from SDN-YooVault on Codex startup.\n\n"
    "Use these values when asked to fill out a form for Dr. Yoo:\n\n"
    f"- Legal name: {i.get('full_legal_name','Frank Kevin Yoo, MD')}\n"
    f"- Goes by: {i.get('preferred_first_name','Kevin')}\n"
    f"- Specialty: {p.get('specialty','Neurological Surgery')}\n"
    f"- NPI: {p.get('npi','')}\n"
    f"- CA Medical License: {p.get('ca_medical_license','')}\n"
    f"- Practice address: {pr.get('street','')}, {pr.get('city','')}, "
    f"{pr.get('state','')} {pr.get('postal_code','')}\n"
    f"- Mailing address: {ma.get('street','')}, {ma.get('city','')}, "
    f"{ma.get('state','')} {ma.get('postal_code','')}\n"
    f"- Office phone: {c.get('office_phone','')}\n"
    f"- Work email: {c.get('work_email','')}\n"
    f"- Practice org: {f.get('primary_practice_org','San Diego Neurosurgery (SDN)')}\n\n"
    "NEVER fill any of the following — direct Dr. Yoo to enter them himself: "
    "bank routing/account numbers, credit card numbers, SSN, EIN/tax IDs, "
    "DEA registration, date of birth, driver's license, passwords, signatures.\n"
)
open(os.environ["OUT"] if "OUT" in os.environ else "/home/azureuser/.openclaw-codex/workspace-codex/DR_YOO_IDENTIFIERS.md", "w").write(md)
PYEOF
echo "[dr-yoo-identifiers-fetch] wrote $OUT"
FETCH_EOF
chmod 0755 "$FETCH"
chown root:root "$FETCH"

# --- patch service unit with ExecStartPre (idempotent) ---------------------
if grep -q "openclaw-codex-fetch-identifiers" "$SYS"; then
  echo "ExecStartPre already present in $SYS"
else
  cp -p "$SYS" "$SYS.bak-$(date +%Y%m%d-%H%M%S)"
  awk -v pre="ExecStartPre=$FETCH" '
    BEGIN { added = 0 }
    { print }
    /^\[Service\]/ && !added { print pre; added = 1 }
  ' "$SYS.bak-$(date +%Y%m%d)-"* > "$SYS.new" 2>/dev/null || \
  awk -v pre="ExecStartPre=$FETCH" '
    BEGIN { added = 0 }
    { print }
    /^\[Service\]/ && !added { print pre; added = 1 }
  ' "$SYS" > "$SYS.new"
  mv "$SYS.new" "$SYS"
  systemctl daemon-reload
  echo "added ExecStartPre to $SYS"
fi

# --- run fetcher once now + restart Codex ----------------------------------
"$FETCH"
systemctl restart openclaw-codex

# --- report ----------------------------------------------------------------
sleep 1
echo "--- service status ---"
systemctl is-active openclaw-codex
echo "--- workspace file ---"
ls -la "$OUT"
head -3 "$OUT"
echo CODEX_TIER2_WIRED
