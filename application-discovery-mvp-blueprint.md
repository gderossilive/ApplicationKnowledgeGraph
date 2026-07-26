# MVP Solution Blueprint – Application Session Discovery & Database Matching

**Obiettivo**  
Costruire un MVP Microsoft-first per osservare sessioni applicative web e desktop, raccogliere eventi UI e metadati SQL, e prepararli per una successiva fase AI di ricostruzione della logica applicativa.

---

## 1. Finalità della soluzione

La soluzione serve a costruire un **Application Knowledge Model** a partire da tre sorgenti principali:

1. **Percorsi utente**: attività reali eseguite dagli utenti su applicazioni web e desktop.
2. **Eventi di interazione UI**: finestre, controlli, campi, pulsanti, focus, click, input/output osservabili.
3. **Metadati e variazioni database SQL**: schema, relazioni, stored procedure, viste e modifiche ai dati.

L'obiettivo finale non è solo fare monitoring, ma produrre una base dati utilizzabile da AI/LLM per generare:

- mappa delle schermate;
- workflow applicativi;
- matrice schermata/campo <-> tabella/colonna;
- regole di business inferite;
- documentazione funzionale;
- backlog di modernizzazione.

---

## 2. Principio guida

Per il MVP la priorità è **minimizzare l'impatto applicativo**.

Quindi l'ordine di adozione consigliato è:

1. **Power Automate Task Mining** – osservazione utente senza modificare l'applicazione.
2. **Microsoft UI Automation Collector** – arricchimento desktop a livello di controlli UI.
3. **SQL Metadata Collector** – estrazione schema e modello dati.
4. **SQL Change/Audit Collector** – osservazione modifiche dati.
5. **OpenTelemetry** – solo su componenti selezionati dove è possibile introdurre strumentazione applicativa.

---

## 3. Architettura logica

```text
+-------------------------------+
| Utenti pilota                 |
+---------------+---------------+
                |
                v
+-------------------------------+
| Livello 1 - Session Capture   |
| - Power Automate Task Mining  |
| - UI Automation Collector     |
+---------------+---------------+
                |
                v
+-------------------------------+
| Event Landing Zone            |
| - Dataverse / Export          |
| - Event Hub                   |
| - Log Analytics               |
+---------------+---------------+
                |
                v
+-------------------------------+
| Livello 2 - Data Discovery    |
| - SQL schema                  |
| - viste                       |
| - stored procedure            |
| - foreign key                 |
| - CDC / Audit / XE            |
+---------------+---------------+
                |
                v
+-------------------------------+
| Livello 3 - AI Matching       |
| - Azure AI Foundry            |
| - Knowledge Graph             |
| - Prompt/agent pipeline       |
+-------------------------------+
```

---

## 4. Componenti principali

### 4.1 Power Automate Task Mining

**Ruolo nel MVP**  
Raccoglie le attività utente sul desktop e consente di comprendere come vengono eseguiti i task operativi.

**Output attesi**

- sequenza delle attività;
- applicazioni utilizzate;
- varianti di processo;
- frequenza dei percorsi;
- process map;
- opportunità di automazione.

**Valore per AI**

Task Mining fornisce una prima rappresentazione del comportamento reale dell'utente. È utile per capire il processo osservato senza dover modificare il codice applicativo.

---

### 4.2 Microsoft UI Automation Collector

**Ruolo nel MVP**  
Arricchisce Task Mining con dettagli più granulari sulle applicazioni desktop Windows.

**Eventi da catturare nel MVP**

```json
{
  "sessionId": "...",
  "timestamp": "...",
  "application": "ClienteLegacy.exe",
  "window": "Customer Search",
  "controlName": "SearchButton",
  "controlType": "Button",
  "eventType": "Invoke",
  "value": null
}
```

**Ambito iniziale**

- finestre attive;
- titolo finestra;
- nome controllo;
- tipo controllo;
- click/invoke;
- focus changed;
- value changed, se disponibile;
- correlazione con session ID.

**Nota di progettazione**  
Non serve coprire tutto da subito. Nel MVP è sufficiente catturare controlli e transizioni principali per 1-2 workflow rilevanti.

---

### 4.3 OpenTelemetry

**Ruolo nel MVP**  
OpenTelemetry va introdotto solo dove è sostenibile strumentare l'applicazione o il runtime.

**Quando usarlo**

- applicazioni web moderne;
- API backend;
- servizi .NET/Java/Node/Python;
- componenti dove è possibile emettere eventi semantici.

**Eventi semantici consigliati**

```json
{
  "traceId": "...",
  "sessionId": "...",
  "userJourneyId": "...",
  "screen": "CustomerSearch",
  "businessEvent": "SearchExecuted",
  "entity": "Customer",
  "entityKeyHash": "...",
  "result": "CustomerFound"
}
```

**Uso consigliato nel MVP**

- non introdurlo come prerequisito per partire;
- usarlo su una schermata o API pilota;
- misurare quanto migliora la qualità del matching UI <-> dati.

---

### 4.4 SQL Metadata Collector

**Ruolo nel MVP**  
Estrae il modello dati senza leggere necessariamente i dati applicativi.

**Metadati minimi**

```sql
-- Tabelle e colonne
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    c.name AS column_name,
    ty.name AS data_type,
    c.max_length,
    c.is_nullable
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
JOIN sys.columns c ON t.object_id = c.object_id
JOIN sys.types ty ON c.user_type_id = ty.user_type_id;
```

```sql
-- Foreign key
SELECT
    fk.name AS foreign_key_name,
    OBJECT_SCHEMA_NAME(fk.parent_object_id) AS parent_schema,
    OBJECT_NAME(fk.parent_object_id) AS parent_table,
    cpa.name AS parent_column,
    OBJECT_SCHEMA_NAME(fk.referenced_object_id) AS referenced_schema,
    OBJECT_NAME(fk.referenced_object_id) AS referenced_table,
    cref.name AS referenced_column
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
JOIN sys.columns cpa ON fkc.parent_object_id = cpa.object_id AND fkc.parent_column_id = cpa.column_id
JOIN sys.columns cref ON fkc.referenced_object_id = cref.object_id AND fkc.referenced_column_id = cref.column_id;
```

```sql
-- Stored procedure e viste
SELECT
    o.type_desc,
    SCHEMA_NAME(o.schema_id) AS schema_name,
    o.name AS object_name,
    m.definition
FROM sys.objects o
JOIN sys.sql_modules m ON o.object_id = m.object_id
WHERE o.type IN ('P', 'V', 'FN', 'IF', 'TF');
```

**Output normalizzato**

```json
{
  "database": "CRM",
  "schema": "dbo",
  "table": "Customer",
  "columns": [
    { "name": "CustomerId", "type": "int", "isPrimaryKey": true },
    { "name": "Status", "type": "nvarchar", "isNullable": false }
  ],
  "relationships": [
    {
      "from": "Customer.CustomerId",
      "to": "Account.CustomerId",
      "type": "foreign_key"
    }
  ]
}
```

---

### 4.5 SQL Change/Audit Collector

**Ruolo nel MVP**  
Osserva le modifiche ai dati per correlare azioni UI e operazioni database.

**Opzioni**

| Opzione | Uso nel MVP | Note |
|---|---|---|
| CDC | Cattura modifiche dati | Utile per vedere before/after su tabelle selezionate |
| SQL Audit | Audit accessi e operazioni | Utile in contesti regolamentati |
| Extended Events | Query/eventi SQL selezionati | Utile per correlare statement e tempi |
| Query Store | Analisi query e performance | Utile per capire pattern applicativi, meno per business event |

**Strategia consigliata**

Per il MVP:

1. partire dallo schema;
2. abilitare CDC o audit solo su poche tabelle critiche;
3. evitare acquisizione massiva dati;
4. pseudonimizzare chiavi e valori sensibili;
5. conservare timestamp coerenti per il matching temporale.

---

## 5. Modello dati comune

Tutti gli eventi devono convergere verso uno schema comune.

### 5.1 Evento UI

```json
{
  "eventType": "ui_event",
  "sessionId": "S-001",
  "timestamp": "2026-07-26T10:11:07Z",
  "application": "CRM Legacy",
  "channel": "desktop",
  "screen": "Customer Search",
  "control": "SearchButton",
  "controlType": "Button",
  "action": "click",
  "inputHash": null,
  "outputHash": null
}
```

### 5.2 Evento database

```json
{
  "eventType": "db_change",
  "timestamp": "2026-07-26T10:11:08Z",
  "database": "CRM",
  "schema": "dbo",
  "table": "Customer",
  "operation": "UPDATE",
  "primaryKeyHash": "...",
  "changedColumns": ["Status"],
  "beforeHash": "...",
  "afterHash": "..."
}
```

### 5.3 Evento semantico OpenTelemetry

```json
{
  "eventType": "app_semantic_event",
  "traceId": "...",
  "sessionId": "S-001",
  "timestamp": "2026-07-26T10:11:08Z",
  "screen": "Customer Search",
  "businessEvent": "CustomerSearchExecuted",
  "entity": "Customer",
  "result": "CustomerFound"
}
```

---

## 6. Matching UI <-> Database

### 6.1 Criteri di correlazione

Il matching può avvenire usando:

- finestra temporale;
- session ID;
- user ID pseudonimizzato;
- machine/device ID;
- trace ID, se disponibile;
- chiavi applicative pseudonimizzate;
- similarità tra nomi UI e colonne DB;
- frequenza ricorrente tra evento UI e modifica DB.

### 6.2 Esempio

```text
10:11:03 - UI - Customer Search - input CustomerId
10:11:07 - UI - SearchButton click
10:11:08 - DB - SELECT/READ Customer
10:11:10 - UI - Customer Detail shown
10:11:22 - UI - ApproveButton click
10:11:23 - DB - UPDATE Customer.Status
```

Inferenza attesa:

```text
SearchButton -> lettura dbo.Customer
ApproveButton -> aggiornamento dbo.Customer.Status
Customer Detail -> rappresentazione UI della tabella Customer
```

---

## 7. Knowledge Graph target

Il risultato atteso è un grafo di conoscenza applicativo.

```text
[Screen: Customer Search]
    contains -> [Control: CustomerIdTextBox]
    contains -> [Control: SearchButton]
    triggers -> [Business Event: CustomerSearchExecuted]
    reads -> [Table: dbo.Customer]

[Screen: Customer Detail]
    displays -> [Column: dbo.Customer.Name]
    displays -> [Column: dbo.Customer.Status]
    contains -> [Control: ApproveButton]
    triggers -> [Stored Procedure: usp_ApproveCustomer]
    writes -> [Column: dbo.Customer.Status]
```

---

## 8. MVP scope consigliato

### Applicazione pilota

Scegliere una sola applicazione con:

- 1 processo end-to-end rilevante;
- 5-20 schermate;
- database SQL accessibile in lettura metadata;
- 3-5 utenti pilota;
- dati sensibili gestibili tramite masking/pseudonimizzazione.

### Workflow pilota

Esempio:

```text
Login
 -> Ricerca cliente
 -> Apertura dettaglio cliente
 -> Modifica stato
 -> Conferma operazione
 -> Verifica esito
```

### Deliverable MVP

1. Process map da Task Mining.
2. Event log UI normalizzato.
3. Catalogo schermate e controlli.
4. Catalogo schema SQL.
5. Lista tabelle/colonne candidate per schermata.
6. Timeline utente + timeline DB.
7. Prima matrice UI <-> DB.
8. Documentazione funzionale generata da AI.
9. Backlog di modernizzazione.

---

## 9. KPI di validazione

| Area | KPI | Target MVP |
|---|---|---|
| Discovery UI | Schermate identificate | >70% del workflow pilota |
| Discovery processo | Varianti principali rilevate | >=3 varianti o tutte quelle osservate nel pilota |
| Discovery DB | Tabelle/relazioni estratte | 100% dello schema in scope |
| Matching | Correlazioni UI <-> DB candidate | >50% sugli step principali |
| AI documentation | Accuratezza review SME | >70% su sezioni funzionali principali |
| Impatto applicativo | Modifiche al codice | 0 per Task Mining/UIA/metadata; limitato solo a OTel pilota |
| Compliance | Dati sensibili in chiaro | 0 nei dataset AI-ready |

---

## 10. Governance e sicurezza

### Principi

- Non raccogliere credenziali.
- Non raccogliere dati personali in chiaro se non strettamente necessario.
- Pseudonimizzare user ID, chiavi cliente e valori sensibili.
- Limitare CDC/audit a tabelle in scope.
- Definire retention breve per raw data e retention più lunga per metadati aggregati.
- Separare raw event store, curated store e knowledge graph.
- Documentare finalità, perimetro e base autorizzativa.

### Classificazione dati

| Dataset | Sensibilità | Azione consigliata |
|---|---|---|
| Eventi UI raw | Alta | Masking e retention breve |
| Metadata schema | Media | Accesso controllato |
| CDC data | Alta | Tabelle selezionate, hashing valori |
| Knowledge graph | Media | No valori sensibili in chiaro |
| Documentazione AI | Media | Review SME prima di condivisione |

---

## 11. Repository suggerito

```text
/application-discovery-mvp
  /docs
    solution-blueprint.md
    security-and-privacy.md
    data-model.md
    ai-prompt-pack.md
  /collectors
    /uia-collector
    /sql-metadata-collector
    /sql-change-collector
  /schemas
    ui-event.schema.json
    db-event.schema.json
    semantic-event.schema.json
  /notebooks
    matching-analysis.ipynb
    graph-generation.ipynb
  /prompts
    generate-screen-catalog.md
    generate-ui-db-matrix.md
    generate-functional-doc.md
  /infra
    bicep-or-terraform
```

---

## 12. Prompt pack iniziale

### 12.1 Generazione catalogo schermate

```text
Analizza gli eventi UI e genera un catalogo delle schermate osservate.
Per ogni schermata indica:
- nome probabile
- controlli principali
- azioni disponibili
- schermate precedenti e successive
- confidenza dell'inferenza
```

### 12.2 Generazione matrice UI <-> DB

```text
Usando eventi UI, metadati SQL e modifiche dati osservate, genera una matrice candidata di mapping tra:
- schermata
- controllo UI
- tabella
- colonna
- tipo relazione: read/write/display/trigger
- evidenza osservata
- livello di confidenza
```

### 12.3 Generazione documentazione funzionale

```text
Genera una documentazione funzionale del workflow osservato.
Includi:
- scopo del processo
- attori
- schermate
- campi principali
- regole di navigazione
- dati letti/scritti
- eccezioni osservate
- assunzioni da validare con SME
```

---

## 13. Roadmap di implementazione

### Fase 1 - Foundation

- definire applicazione pilota;
- definire processo in scope;
- definire data classification;
- definire schema evento comune;
- predisporre ambiente Power Platform/Azure.

### Fase 2 - Session Capture

- attivare Task Mining su utenti pilota;
- raccogliere sessioni controllate;
- esportare/normalizzare eventi;
- generare prima process map.

### Fase 3 - UI Automation Enrichment

- creare collector UIA minimale;
- catturare finestre, controlli e azioni principali;
- correlare eventi UIA con sessioni Task Mining.

### Fase 4 - SQL Discovery

- estrarre schema SQL;
- estrarre relazioni;
- estrarre viste/procedure in scope;
- creare data model graph.

### Fase 5 - SQL Change Capture mirata

- selezionare 2-5 tabelle critiche;
- abilitare CDC/audit/Extended Events dove appropriato;
- raccogliere eventi DB durante sessioni pilota.

### Fase 6 - AI Matching

- caricare eventi e metadati in formato JSON/Parquet;
- generare screen graph;
- generare data graph;
- produrre matrice UI <-> DB;
- validare con SME.

### Fase 7 - Output di valore

- documentazione funzionale;
- mappa applicativa;
- mappa dei dati;
- opportunità di automazione;
- backlog di modernizzazione.

---

## 14. Fonti ufficiali e riferimenti

- Power Automate Task Mining overview: https://learn.microsoft.com/en-us/power-automate/task-mining-overview
- Power Automate Process Mining and Task Mining overview: https://learn.microsoft.com/en-us/power-automate/process-advisor-overview
- Power Automate Process Mining overview: https://learn.microsoft.com/en-us/power-automate/process-mining-overview
- Copilot in Process Mining analytics: https://learn.microsoft.com/en-us/power-automate/process-mining-copilot-in-process-analytics
- Application Insights with Power Automate: https://learn.microsoft.com/en-us/power-platform/admin/app-insights-cloud-flow
- Azure Monitor OpenTelemetry: https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-overview
- Enable Azure Monitor OpenTelemetry: https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-enable
- Azure SQL CDC overview: https://learn.microsoft.com/en-us/azure/azure-sql/database/change-data-capture-overview
- SQL Server CDC administration: https://learn.microsoft.com/en-us/sql/relational-databases/track-changes/administer-and-monitor-change-data-capture-sql-server

---

## 15. Sintesi finale

La soluzione MVP consigliata è una piattaforma di **Application Discovery AI-ready** composta da:

```text
Power Automate Task Mining
+ UI Automation Collector
+ SQL Metadata/Change Collector
+ OpenTelemetry selettivo
+ Azure Monitor / Log Analytics / Event Hub
+ Azure AI Foundry / Knowledge Graph
```

Il valore principale è trasformare osservazioni operative sparse in un modello strutturato dell'applicazione:

```text
Utente -> Schermata -> Controllo -> Evento -> Dato -> Regola -> Documento -> Backlog
```

Questo permette di supportare iniziative di modernizzazione, automazione, audit applicativo e reverse engineering funzionale con un impatto iniziale molto basso sulle applicazioni esistenti.
