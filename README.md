# O365 Management Activity → Event Hubs → Azure Data Explorer (ADX)

Azure Function (PowerShell) that pulls **Office 365 Management Activity API** events (Audit.General / DLP.All), paginates & filters by **RecordType**, and publishes **one JSON per message** to **Azure Event Hubs** using **Managed Identity**.  
ADX consumes from Event Hubs into a **raw table**; KQL parsers (in `/kql/`) project friendly columns for Endpoint, SharePoint and OneDrive.

O365 Mgmt API –> Azure Function (PS) –> Event Hubs –> (Data Connection) –> ADX (Raw) -> Azure Table (checkpoint: lastExecutionEndTime)

---

## 🚀 Deploy with one click

These buttons open the Azure portal with this repo’s ARM template.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fbrunofreitas-br%2FPurviewDLPLogsToADX%2Fmain%2Fazuredeploy.json)

[![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fbrunofreitas-br%2FPurviewDLPLogsToADX%2Fmain%2Fazuredeploy.json)

---

## 📦 What this deploys

- Azure **Function App** (PowerShell 7) with **System-Assigned Managed Identity**
- App Settings for O365 Mgmt API, timer schedule, and Event Hubs output (via MI)
- Azure Storage for Function content + **Azure Table** used as **checkpoint**
- (You connect Event Hubs → ADX after deploy; steps below)

---

## ✅ Prerequisites

- Azure subscription & Resource Group
- **Event Hubs** Namespace + Event Hub (no connection string needed; we use MI)
- **Azure Data Explorer** (Kusto) cluster & database
- **Entra ID App Registration** for the O365 Mgmt Activity API:
  - API permissions (Application): `ActivityFeed.Read` and `ActivityFeed.ReadDlp`
  - **Client ID / Secret**, **Tenant ID**, **Tenant Domain**
  - A **PublisherIdentifier** (any GUID)
- **O365 Mgmt API subscriptions** enabled for desired content types:
  - Example (PowerShell):
    ```powershell
    $Publisher = "<GUID>"   # e.g., from https://www.guidgenerator.com/
    Invoke-WebRequest -Method Post -Headers $headerParams `
      -Uri "https://manage.office.com/api/v1.0/$tenantGuid/activity/feed/subscriptions/start?contentType=Audit.General&PublisherIdentifier=$Publisher"
    Invoke-WebRequest -Method Post -Headers $headerParams `
      -Uri "https://manage.office.com/api/v1.0/$tenantGuid/activity/feed/subscriptions/start?contentType=DLP.ALL&PublisherIdentifier=$Publisher"
    ```

---

## ⚙️ App Settings (Function)

| Setting | Example | Description |
|---|---|---|
| `Schedule` | `0 */5 * * * *` | Timer CRON (every 5 mins) |
| `EVENTHUB_NAME` | `o365-logs` | Event Hub name (output) |
| `EventHubConnection__fullyQualifiedNamespace` | `myns.servicebus.windows.net` | EH namespace FQDN |
| `contentTypes` | `Audit.General,DLP.ALL` | O365 Mgmt API content types |
| `recordTypes` | `0` | `0` = all; or list `11,13,33,63,107` |
| `clientID` | `xxxxxxxx-...` | Entra App (client) ID |
| `clientSecret` | `***` | Entra App client secret (or KV ref) |
| `domain` | `contoso.onmicrosoft.com` | Tenant domain |
| `publisher` | `<guid>` | PublisherIdentifier |
| `tenantGuid` | `xxxxxxxx-...` | Tenant ID |
| `AzureAADLoginUri` | `https://login.microsoftonline.com` | Auth URL |
| `OfficeLoginUri` | `https://manage.office.com` | O365 Mgmt API URL |
| `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` | `DefaultEndpointsProtocol=...` | Storage (for checkpoint) |
| `EXCLUDE_MCAS` (optional) | `true` | Skip events where `Source == "Cloud App Security"` |

> The Event Hubs output binding uses **Managed Identity**—no connection string required.

---

## 🔐 RBAC: Function Managed Identity → Event Hubs

Grant **Azure Event Hubs Data Sender** to the Function’s MI **on the EH namespace**:

```bash
# Enable MI (if not yet)
az functionapp identity assign -g <RG_APP> -n <FUNCTION_APP_NAME>

# Get principalId
PID=$(az functionapp identity show -g <RG_APP> -n <FUNCTION_APP_NAME> --query principalId -o tsv)

# Get EH namespace scope
EH_SCOPE=$(az eventhubs namespace show -g <RG_EH> -n <EH_NAMESPACE> --query id -o tsv)

# Grant role
az role assignment create --assignee $PID --role "Azure Event Hubs Data Sender" --scope $EH_SCOPE
```

---

## 🔗 Connect Event Hubs to ADX

### 1) Create **raw table** + JSON mapping (in ADX)

Open ADX (Kusto) query window (target database):

```kusto
// Raw table with a single dynamic column that stores the full event JSON
.create table PurviewDLP_Raw (Event: dynamic);

// Ingestion mapping: capture whole payload into Event
.create-or-alter table PurviewDLP_Raw ingestion json mapping 'RawJson'
'[{"column":"Event","datatype":"dynamic","path":"$"}]'
```

### 2) Create the **Data Connection** (EH → ADX)

**Portal path:** Cluster → Database → **Data connections** → **Add**  
- Source: **Event Hub**  
- Namespace / Event Hub: select yours  
- Consumer Group: e.g., `$Default` or a dedicated one like `adx-purview`  
- Table: `PurviewDLP_Raw`  
- Data format: `JSON`  
- Mapping: `RawJson`

---

## 🧪 Quick validation

- **Function logs:** look for lines like  
  `INFORMATION: EH debug: seen=…, added=…, skipType=…, includeAll=…`
- **Event Hubs metrics:** check Ingress/Egress on the Event Hub (namespace → event hub → Metrics)
- **ADX raw data:**
  ```kusto
  PurviewDLP_Raw
  | take 5
  ```
- **Parsers:** import the `.kql` files from `/KQL Parsers/` and then:
  ```kusto
  PurviewDLPLogs_Endpoint()   | take 5
  PurviewDLPLogs_SharePoint() | take 5
  PurviewDLPLogs_OneDrive()   | take 5
  PurviewDLPLogs_Exchange()   | take 5
  ```

---

## 🛠️ Troubleshooting

- **No EH messages**
  - Confirm RBAC: Function MI has **Azure Event Hubs Data Sender** on the **namespace**
  - Check `EVENTHUB_NAME` and `EventHubConnection__fullyQualifiedNamespace`
  - Temporarily set `recordTypes=0` to disable filtering and re-test

- **ADX ingestion errors**
  - Query failures:
    ```kusto
    .show ingestion failures
    | where Table == "PurviewDLP_Raw"
    | take 50
    ```
  - Error “MissingMapping” → ensure the Data Connection uses **JSON** format and the **RawJson** mapping

- **ADX table empty**
  - Validate the Data Connection’s **Consumer Group** and EH metrics (Ingress/Egress)
  - Check ADX **retention** & **caching** policies if querying older windows

---
