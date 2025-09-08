
# Azure CLI deploy helper — azurecli-deploy/deploy_sql.sh

This folder contains `deploy_sql.sh`, an interactive script that creates an Azure SQL Server, a small initial database, a firewall rule, and assigns an Azure Entra (AD) admin.

Important: all users who will run this script already have the required Azure permissions in the target subscription/resource groups. Authenticate using `az login` or run the script inside Cloud Shell / agents that already run under the appropriate credentials.

Quick usage
1) Preview the planned changes (safe dry-run — no Azure calls):
```bash
DRY_RUN=1 ./deploy_sql.sh
```

2) Run interactively to create resources (the script will prompt for secrets and confirmations):
```bash
./deploy_sql.sh
```

3) Non-interactive / CI-run with automatic 'yes' behavior:
```bash
# Export env vars (see below) and set AUTO_YES=1 to skip interactive subscription and final-confirm prompts
DRY_RUN=1 AUTO_YES=1 ./deploy_sql.sh
```

How to deploy (clone → login → run)
-----------------------------------
Follow these steps on a local machine or CI runner to download the repo, authenticate to Azure, preview the plan, and run the deployment.

1) Clone locally and prepare scripts
```bash
git clone https://github.com/ngwakevin/kngwa.git
cd kngwa/azurecli-deploy
chmod +x deploy_sql*.sh
```

2) Ensure required tools
- Azure CLI (az): verify with `az --version`
- python3: `python3 --version` (used to parse capability JSON)
- Shell: `zsh` or `bash` (script developed for zsh)
- Optional: PowerShell Core (`pwsh`) on Windows

3) Login to Azure
CLI (recommended):
```bash
az login
# optionally select a subscription by name or id
az account set --subscription "Azure Enterprise Development"  # or the subscription id
```

PowerShell (optional):
```powershell
Connect-AzAccount
Select-AzSubscription -SubscriptionName "Azure Enterprise Development"
```

4) Preview (safe DRY_RUN) — no Azure changes
Provide env vars (example) and run a dry-run to preview the planned resources:
```bash
DRY_RUN=1 AUTO_YES=1 \
RESOURCE_GROUP=rg-infra-dev \
LOCATION=centralus \
SQL_SERVER_NAME=sql-test-new \
SQL_ADMIN_USER=sqladmin \
SQL_ADMIN_PASS='S3cr3t!' \
SQL_DB_NAME=dbtest \
SERVICE_OBJECTIVE=S1 \
DESIRED_MAX_SIZE_RAW=10GB \
BACKUP_STORAGE_REDUNDANCY=Local \
FIREWALL_START_IP=0.0.0.0 \
FIREWALL_END_IP=0.0.0.0 \
ENTRA_ADMIN_UPN='user@contoso.onmicrosoft.com' \
ENTRA_ADMIN_OBJECT_ID='00000000-0000-0000-0000-000000000000' \
TAG_OWNER='you@contoso.com' \
TAG_PROJECTNAME='Infra' \
TAG_BUSINESSUNIT='Infra' \
TAG_DEPLOYBY='automation' \
TAG_APPLICATIONNAME='app' \
./deploy_sql.sh
```

5) Run (create resources)
Remove `DRY_RUN=1` to make the changes. Use `AUTO_YES=1` for CI or to skip interactive prompts.
```bash
AUTO_YES=1 \
RESOURCE_GROUP=rg-infra-dev \
LOCATION=centralus \
SQL_SERVER_NAME=sql-test-new \
SQL_ADMIN_USER=sqladmin \
SQL_ADMIN_PASS='S3cr3t!' \
SQL_DB_NAME=dbtest \
SERVICE_OBJECTIVE=S1 \
DESIRED_MAX_SIZE_RAW=10GB \
BACKUP_STORAGE_REDUNDANCY=Local \
FIREWALL_START_IP=1.2.3.4 \
FIREWALL_END_IP=1.2.3.4 \
ENTRA_ADMIN_UPN='user@contoso.onmicrosoft.com' \
ENTRA_ADMIN_OBJECT_ID='00000000-0000-0000-0000-000000000000' \
TAG_OWNER='you@contoso.com' \
TAG_PROJECTNAME='Infra' \
TAG_BUSINESSUNIT='Infra' \
TAG_DEPLOYBY='automation' \
TAG_APPLICATIONNAME='app' \
./deploy_sql.sh
```

6) Existing Resource Group flow
If you already have a Resource Group and want to deploy into it, use the existing-RG helper which also accepts flags:
```bash
DRY_RUN=1 AUTO_YES=1 ./deploy_sql_existing_rg.sh --rg rg-infra-dev --location centralus --server sql-test-new --admin-user sqladmin --admin-pass 'S3cr3t!' --db dbtest --objective S1 --max-size 10GB --start-ip 1.2.3.4 --end-ip 1.2.3.4 --entra 4
```

CI notes and security
- Store secrets (e.g., `SQL_ADMIN_PASS`) in your CI secret store and inject them as environment variables at runtime.
- Use `DRY_RUN=1` when validating pipeline changes. Flip to `DRY_RUN=0` or omit it to execute.

Troubleshooting
- If `az` reports permission or tenant errors, run `az login` and `az account set --subscription <id|name>`.
- If capacity/capabilities cannot be read from Azure, the script falls back to conservative defaults and may remove `--max-size` on retry.
- On Windows, use PowerShell Core (`pwsh`) or WSL to run the scripts.


What the script will ask for (explicit list)
- Resource Group name (RESOURCE_GROUP)
	- Example: `<RESOURCE_GROUP>` (e.g. `rg-dev-01`)
	- Validation: trimmed; used verbatim. If the RG exists the script will show current resources and ask to continue.
- Azure region / location (LOCATION)
	- Example: `<LOCATION>` (e.g. `centralus`, `eastus2`) — typos will cause an Azure error
- SQL Server name (SQL_SERVER_NAME)
	- Example: `<SQL_SERVER_NAME>` (global-unique identifier)
	- Must be globally unique within Azure SQL servers in the subscription.
- SQL Admin username (SQL_ADMIN_USER)
	- Example: `<SQL_ADMIN_USER>` (e.g. `sqladmin`)
- SQL Admin password (SQL_ADMIN_PASS)
	- Input is hidden when typed.
- SQL Database name (SQL_DB_NAME)
	- Example: `<SQL_DB_NAME>` (e.g. `appdb`)
	- Characters allowed: letters, digits, dot (.), underscore (_), hyphen (-). The script will suggest a sanitized name if invalid characters are entered.
	- Default service objective used by the script: Basic, max-size 2GB (small starter database to grow later).
- Firewall start and end IP (FIREWALL_START_IP / FIREWALL_END_IP)
	- Default is `0.0.0.0` for public access (you can restrict to your client IP or a CIDR range).
- Azure Entra (AD) admin selection (ENTRA_ADMIN_UPN / ENTRA_ADMIN_OBJECT_ID)
	- The script lists a small set of UPNs + object IDs and asks you to choose one. The selected UPN and object id are used with `az sql server ad-admin create`.
- Resource Group tags (Owner, ProjectName, BusinessUnit, DeployBy, ApplicationName)
	- Optional values; they are applied when creating/updating the RG.
- Backup storage redundancy selection (BACKUP_STORAGE_REDUNDANCY)
	- Options: `Local` (default), `Geo`, `Zone` (script normalizes values).
- Final confirmation prompts
	- The script prints a clear planned-resources summary (Resource Group, SQL Server, DB, Firewall rule, Entra admin, tags) and asks `Proceed? (Y/n)` before any Azure changes.

Environment variables (for non-interactive / CI usage)
The script accepts values from the environment. You can export these before running the script in CI or a wrapper:

	RESOURCE_GROUP
	LOCATION
	SQL_SERVER_NAME
	SQL_ADMIN_USER
	SQL_ADMIN_PASS (mark secret in pipeline)
	SQL_DB_NAME
	FIREWALL_START_IP
	FIREWALL_END_IP
	ENTRA_ADMIN_UPN
	ENTRA_ADMIN_OBJECT_ID
	TAG_OWNER
	TAG_PROJECTNAME
	TAG_BUSINESSUNIT
	TAG_DEPLOYBY
	TAG_APPLICATIONNAME
	BACKUP_STORAGE_REDUNDANCY
	DRY_RUN (set to `1` to preview; `0` to execute)
	AUTO_YES (set to `1` to auto-accept subscription and final confirmation prompts)

Preset subscription
- The script includes a preset subscription entry for convenience ("Azure Enterprise Development" — id `eb252d81-f912-42c7-b654-e8f1bf9a4bb0`).
  When choosing a subscription interactively the preset will appear alongside subscriptions discovered by `az account list` and be marked `[preset]`.

Example (CI wrapper):
```bash
export RESOURCE_GROUP='<RESOURCE_GROUP>'
export LOCATION='<LOCATION>'
export SQL_SERVER_NAME='<SQL_SERVER_NAME>'
export SQL_ADMIN_USER='<SQL_ADMIN_USER>'
export SQL_ADMIN_PASS='$(sql_admin_secret)'
export SQL_DB_NAME='<SQL_DB_NAME>'
export FIREWALL_START_IP='0.0.0.0'
export FIREWALL_END_IP='0.0.0.0'
export ENTRA_ADMIN_UPN='<ENTRA_ADMIN_UPN>'
export ENTRA_ADMIN_OBJECT_ID='<ENTRA_ADMIN_OBJECT_ID>'
export BACKUP_STORAGE_REDUNDANCY='Local'
export DRY_RUN='0'
./deploy_sql.sh
```


Required tools on your machine / runner
- Azure CLI (`az`) — use a recent version for best compatibility.
- `python3` — used by the script to parse Azure capability JSON (optional fallback exists if missing).
- `zsh` or `bash` shell to run the script (script was developed for `zsh` but is POSIX-friendly where possible).

Behavior notes
- The script defaults to creating a very small DB (Basic, 2GB) to minimize cost and grow later.
- If the Azure CLI on the runner doesn't support `--backup-storage-redundancy`, the script will retry server creation without that flag.
- Database names are sanitized automatically; the script will prompt to accept a suggested sanitized name when invalid characters are provided.

If you want, I can update the script to add an `--yes`/`AUTO_APPROVE` flag and a documented non-interactive mode so the pipeline can run without any TTY prompts.

Azure CLI helper scripts to create Azure SQL servers and databases.

Files
- `deploy_sql.sh` - creates a new resource group, SQL server and database interactively.
- `deploy_sql_existing_rg.sh` - creates SQL server/database inside an existing resource group.

Usage
- Make scripts executable: `chmod +x deploy_sql*.sh`
- Run interactively: `./deploy_sql_existing_rg.sh`
- For CI usage you can pass many flags to the existing-RG script (see help inside the script).

Notes
- Scripts use `az sql db list-editions -l <location>` to validate service objective vs requested max size. If the CLI doesn't return capabilities, a conservative fallback is used.
