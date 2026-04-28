\# OpenEMR Local Setup — Stage 1



This document captures the exact, working path to run OpenEMR locally with realistic synthetic patient data. It also records the gotchas hit along the way and the data-quality observations from the imported dataset, which feed forward into the Stage 3 audit.



Tested on: Windows 11, PowerShell 5.1, Docker Desktop 4.x, Eclipse Temurin OpenJDK 21.



\---



\## 1. Prerequisites



| Tool | Version | Purpose |

|------|---------|---------|

| Docker Desktop | 4.x or newer | Runs the OpenEMR development stack |

| Git | 2.x | Clone the fork |

| Java JDK | 11+ (21 used here) | Run the Synthea synthetic patient generator |

| PowerShell | 5.1 or 7.x | All commands below |



Install Java if missing:



```powershell

winget install EclipseAdoptium.Temurin.21.JDK

\# Open a fresh PowerShell, then:

java -version

```



\---



\## 2. Clone the fork



```powershell

cd C:\\Users\\tyler

git clone https://github.com/tylerxia8/openemr.git

cd openemr

```



> \*\*Note on source archives.\*\* GitHub's `master.zip` source export omits the `docker/` directory because of `.gitattributes` `export-ignore` rules. A `git clone` is the correct way to obtain a working dev environment — the zip alone cannot bring up the stack.



\---



\## 3. Bring up the development stack



OpenEMR ships an "easy dev" Compose project that wires up the full stack — OpenEMR, MariaDB, phpMyAdmin, OpenLDAP, Mailpit, Selenium, CouchDB.



```powershell

cd C:\\Users\\tyler\\openemr\\docker\\development-easy

docker compose up -d

docker compose logs -f openemr

```



The first start takes 3–5 minutes (asset compilation + DB installer). Watch the logs until OpenEMR reports it is ready, then Ctrl-C out of the log stream.



\### Services and ports



| Service    | Image                     | URL / Port             |

|------------|---------------------------|------------------------|

| openemr    | openemr/openemr:flex      | http://localhost:8300  |

| mysql      | mariadb:11.8              | localhost:8320         |

| phpmyadmin | phpmyadmin:latest         | http://localhost:8310  |

| mailpit    | axllent/mailpit:1.29      | http://localhost:8025  |

| openldap   | openemr/dev-ldap:easy     | 389 / 636 (internal)   |

| selenium   | selenium/standalone-chromium | http://localhost:4444 |

| couchdb    | couchdb:3.5               | http://localhost:5984  |



\### Verify



Open `http://localhost:8300`. Log in with `admin` / `pass`. You should land on the empty calendar / dashboard.



\---



\## 4. Generate synthetic patient data (Synthea)



Synthea produces realistic FHIR R4 + CCDA documents for fake-but-realistic patients with full longitudinal medical histories.



```powershell

$work = "$env:USERPROFILE\\synthea"

New-Item -ItemType Directory -Path $work -Force | Out-Null

$ProgressPreference = 'SilentlyContinue'   # speeds the download dramatically

Invoke-WebRequest 'https://github.com/synthetichealth/synthea/releases/download/master-branch-latest/synthea-with-dependencies.jar' `

&#x20;   -OutFile "$work\\synthea.jar" -UseBasicParsing



Push-Location $work

java -jar synthea.jar -p 25 `

&#x20;   --exporter.ccda.export=true `

&#x20;   --exporter.fhir.export=true `

&#x20;   --exporter.csv.export=false `

&#x20;   --exporter.html.export=false `

&#x20;   Massachusetts

Pop-Location

```



Output lands in `\~\\synthea\\output\\ccda\\\*.xml` and `\~\\synthea\\output\\fhir\\\*.json`. CCDA is what OpenEMR's importer ingests; FHIR is kept for later use (Stage 5 agent integration).



> \*\*Synthea oddity.\*\* `-p 25` produces 25 patient records but the importer ends up creating 26 rows in `patient\_data`. The extra row appears to be a synthetic provider/facility CCDA Synthea emits alongside the patient bundles.



\---



\## 5. Stage CCDAs inside the OpenEMR container



```powershell

cd C:\\Users\\tyler\\openemr\\docker\\development-easy

docker compose cp "$env:USERPROFILE\\synthea\\output\\ccda" openemr:/tmp/ccda

docker compose exec openemr ls /tmp/ccda | Measure-Object | Select-Object Count

```



Local count and container count should match.



\---



\## 6. Bulk import the CCDAs



The OpenEMR repo ships a CLI importer at `contrib/util/ccda\_import/import\_ccda.php`. Two non-obvious requirements that we hit during setup:



1\. The script refuses to run unless `OPENEMR\_ENABLE\_CCDA\_IMPORT=1` is set in its environment (intentional safety guard).

2\. Per its own header comments, \*\*the script "is not working at this time if development mode is turned off"\*\* — so `--isDev=true` is mandatory in practice.



Working command:



```powershell

docker compose exec -e OPENEMR\_ENABLE\_CCDA\_IMPORT=1 openemr bash -lc `

&#x20; "php /var/www/localhost/htdocs/openemr/contrib/util/ccda\_import/import\_ccda.php --sourcePath=/tmp/ccda --site=default --openemrPath=/var/www/localhost/htdocs/openemr --isDev=true" 2>\&1 `

&#x20; | Tee-Object -FilePath "$env:USERPROFILE\\synthea\\bulk-import.log"

```



The script processes every `\*.xml` in `--sourcePath` in one pass — no per-file loop needed. Total runtime for 25 patients: \~2 minutes.



`--sourcePath` is a directory, not a file. Passing a single file does not work.



\---



\## 7. Verify the import



```powershell

docker compose exec mysql mariadb -uroot -proot openemr -e "

SELECT 'patients'    AS tbl, COUNT(\*) AS n FROM patient\_data

UNION ALL SELECT 'encounters',  COUNT(\*) FROM form\_encounter

UNION ALL SELECT 'problems',    COUNT(\*) FROM lists WHERE type='medical\_problem'

UNION ALL SELECT 'medications', COUNT(\*) FROM lists WHERE type='medication'

UNION ALL SELECT 'allergies',   COUNT(\*) FROM lists WHERE type='allergy';"

```



\### What this run produced



| Table       | Rows |

|-------------|-----:|

| patients    |   26 |

| encounters  | 1604 |

| problems    |  923 |

| medications |  121 |

| allergies   |   10 |



Open `http://localhost:8300` → Patients → Patient List. You should see Synthea-generated names (e.g. "Maria Smith", "John Garcia"). Click into one to confirm encounters and problems load.



\---



\## 8. Known issues and gotchas



\- \*\*GitHub source zip strips `docker/`.\*\* Always use `git clone`, never the source archive, for a working dev environment.

\- \*\*`import\_ccda.php` fails silently if `OPENEMR\_ENABLE\_CCDA\_IMPORT=1` is missing.\*\* It prints "Set the env var..." and exits 0, which looks like success.

\- \*\*`--isDev=true` is required.\*\* The script's own header notes it does not function with development mode off. Production-mode import is broken at HEAD.

\- \*\*`--sourcePath` must be a directory.\*\* Passing a single file path produces no error but no rows either.

\- \*\*OpenEMR path inside the `flex` image is `/var/www/localhost/htdocs/openemr`\*\* (Alpine layout). Other distributions of OpenEMR use `/var/www/openemr` or `/var/www/html/openemr`. Check inside the container before scripting paths.

\- \*\*Module Manager UI path varies.\*\* The dev-easy image has `Carecoordination` enabled by default, so the click-through enable step in some docs is unnecessary — confirm via `SELECT mod\_active FROM modules WHERE mod\_name='Carecoordination'`.



\---



\## 9. Data quality observations (Stage 3 starter material)



These are anomalies in the import that will become Data Quality findings in `AUDIT.md`:



\- \*\*Medication coverage is low.\*\* 121 rows across 26 patients (\~4.6 each) is well below what Synthea normally emits. The CCDA → OpenEMR mapping likely captures only the active medication section, dropping historical/discontinued meds. \*\*This is silent data loss the agent must not assume away.\*\*

\- \*\*Allergy coverage is very low.\*\* 10 allergies total across 26 patients (\~38% have any). Synthea's allergy generator produces more than this; the gap is almost certainly in the parser, not the source data.

\- \*\*Problem counts are realistic.\*\* 923 problems across 26 patients (\~35 each) — includes resolved problems, which is good for testing query filters.

\- \*\*Encounter counts are realistic.\*\* 1604 encounters (\~62 per patient) reflects Synthea's longitudinal modeling of a multi-year history.

\- \*\*Importer logs warnings worth reviewing.\*\* Inspect `\~\\synthea\\bulk-import.log` for parser errors — file-by-file failures are real audit material.



\---



\## 10. Tear down / restart



```powershell

cd C:\\Users\\tyler\\openemr\\docker\\development-easy



\# stop without losing data

docker compose stop



\# stop and remove containers (volumes preserved)

docker compose down



\# nuclear option — also remove volumes (you lose the database and imported patients)

docker compose down -v

```



To re-import after a `down -v`, re-run sections 5 and 6 — the Synthea output in `\~\\synthea\\output\\` does not need to be regenerated.



\---



\## 11. What's next



\- \*\*Stage 2 — Deploy:\*\* push this fork to a public host (Render / Railway / Fly.io for container deploys, or DigitalOcean for a plain VM running the same compose stack).

\- \*\*Stage 3 — Audit:\*\* see the data-quality starters in §9 above; expand into security, performance, architecture, compliance.

\- \*\*Stages 4–5:\*\* target user definition and agent architecture plan, both grounded in what the audit reveals about the actual system.

