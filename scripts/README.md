# Scripts E6 — Infrastructure yanixlabs.lan

Bibliothèque de scripts PowerShell prod-ready pour le déploiement et l'administration
de l'infrastructure du projet E6 BTS SIO SISR.

**Auteur** : Yanis HARRAT — BTS SIO SISR — Juin 2026
**Conformité** : Microsoft Approved Verbs, ANSSI PA-022 (R.16, R.18, R.20, R.22), AGDLP, RGPD

## Structure

```
scripts/
├── _common/                              Bibliothèque commune (sourcée par tous)
│   ├── Common.ps1                        Logger, pre-flight, télémétrie
│   ├── AD-Helpers.ps1                    Helpers Active Directory
│   ├── FS-Helpers.ps1                    Helpers fichiers et ACL
│   └── Test-Foundation.ps1               Validation de la bibliothèque
├── _config/
│   └── E6-Config.psd1                    Configuration centralisée
├── Logs/                                 Logs horodatés (auto-créé)
├── 01-08-bootstrap_*.ps1                 Scripts de déploiement initial
├── 10-14-ops_*.ps1                       Scripts d'opérations quotidiennes
├── 20-21-maintenance_*.ps1               Scripts d'audit et nettoyage
├── backup-centralise.ps1                 Orchestrateur de sauvegarde (sur BCK-01)
└── README.md                             Ce fichier
```

## Liste complète des scripts

### Phase 1 — BOOTSTRAP (déploiement initial, une seule fois)

| # | Script | Cible | Description |
|---|---|---|---|
| 01 | `bootstrap_AD-Structure` | SRV-DC-01 | OUs + groupes AGDLP + comptes (nominal, admin Tier 0, démo) |
| 02 | `bootstrap_DHCP-Failover` | SRV-DC-01 | DHCP sur les 2 DC + Failover LoadBalance 50/50 (MCLT 5min) |
| 03 | `bootstrap_FS01-Shares` | SRV-FS-01 | 12 partages SMB avec ACL AGDLP stricte |
| 04 | `bootstrap_FS02-Setup` | SRV-FS-02 | Setup VM (réseau, rôles FS/DFS, disque D: DATA) |
| 05 | `bootstrap_DFS-NR` | SRV-DC-01 | Namespace DFS-N + 12 RG DFS-R |
| 06 | `bootstrap_Shadow-Copies` | SRV-FS-01/02 | VSS Shadow Copies horaires (PRA Niveau 1) |
| 07 | `bootstrap_BCK01-Setup` | SRV-BCK-01 | Setup VM + partage Backups + Logs$ (télémétrie) |
| 08 | `bootstrap_Backup-Orchestrator` | SRV-DC-01 | Install WSB partout + tâche planifiée sur BCK-01 |

### Phase 2 — OPS (opérations quotidiennes)

| # | Script | Cible | Description |
|---|---|---|---|
| 10 | `ops_Add-NewUser` | SRV-DC-01 | Onboarding atomique utilisateur (AD + home + ACL + groupes + fiche) |
| 11 | `ops_Client-Join-Domain` | Poste client | Jonction d'un poste W11 au domaine dans la bonne OU |
| 12 | `ops_Provision-Homes-Batch` | SRV-DC-01 | Provisionnement des homes pour tous les users existants |
| 13 | `ops_Reset-Password` | SRV-DC-01 | Reset MDP ciblé ou en masse (avec exclusions safety) |
| 14 | `ops_Create-Admin-Account` | SRV-DC-01 | Création d'un compte admin Tier 0 (confirmation explicite) |

### Phase 3 — MAINTENANCE (audits périodiques)

| # | Script | Cible | Description |
|---|---|---|---|
| 20 | `maintenance_Audit-Duplicates` | SRV-DC-01 | Audit READ-ONLY (9 sections) + rapport TXT |
| 21 | `maintenance_Cleanup-Duplicates` | SRV-DC-01 | Cleanup interactif des anomalies détectées |

### Annexes

| Fichier | Description |
|---|---|
| `backup-centralise.ps1` | Orchestrateur de sauvegarde planifié sur SRV-BCK-01 |
| `_common/Test-Foundation.ps1` | À lancer en premier sur chaque serveur pour valider la lib |

## Première utilisation

### 1. Déployer la bibliothèque sur chaque serveur

Depuis n'importe quel poste avec accès admin :

```powershell
robocopy "<source_scripts>" "\\SRV-DC-01\C$\Scripts" /E /R:1 /W:1 /XD Logs
robocopy "<source_scripts>" "\\SRV-DC-02\C$\Scripts" /E /R:1 /W:1 /XD Logs
robocopy "<source_scripts>" "\\SRV-FS-01\C$\Scripts" /E /R:1 /W:1 /XD Logs
robocopy "<source_scripts>" "\\SRV-FS-02\C$\Scripts" /E /R:1 /W:1 /XD Logs
robocopy "<source_scripts>" "\\SRV-BCK-01\C$\Scripts" /E /R:1 /W:1 /XD Logs
```

### 2. Valider la fondation sur chaque serveur

Sur chaque serveur en PowerShell admin :

```powershell
cd C:\Scripts
.\_common\Test-Foundation.ps1
```

Doit retourner 0 erreur (3 warnings tolérés : DC-02 down, télémétrie pas encore prête, etc.).

### 3. Ordre de déploiement recommandé

1. `01-bootstrap_AD-Structure.ps1` (sur DC-01)
2. `02-bootstrap_DHCP-Failover.ps1` (sur DC-01)
3. `04-bootstrap_FS02-Setup.ps1` (sur FS-02)
4. `03-bootstrap_FS01-Shares.ps1` (sur FS-01)
5. `05-bootstrap_DFS-NR.ps1` (sur DC-01 ou FS-01)
6. `06-bootstrap_Shadow-Copies.ps1` (sur FS-01 puis FS-02)
7. `07-bootstrap_BCK01-Setup.ps1` (sur BCK-01)
8. `08-bootstrap_Backup-Orchestrator.ps1` (sur DC-01)

Pour chaque script, **toujours commencer par `-DryRun`** pour valider avant exécution réelle.

## Standards prod-ready appliqués

Tous les scripts respectent les principes suivants :

| Principe | Implémentation |
|---|---|
| Documentation | En-tête `<# .SYNOPSIS .DESCRIPTION .PARAMETER .EXAMPLE .NOTES #>` |
| Validation des inputs | `[ValidateSet]`, `[ValidatePattern]`, regex Unicode `\p{L}` |
| Élévation requise | `Test-YanixIsAdmin` au démarrage |
| Idempotence | Vérification d'état avant chaque action |
| Mode simulation | Switch `-DryRun` natif sur tous les scripts |
| Gestion d'erreurs | `try/catch` + `$ErrorActionPreference = 'Stop'` |
| Traçabilité | Logger structuré (fichier UTF-8 + console + télémétrie) |
| Vérification post | Fonction `Test-*` intégrée, appelée automatiquement (bootstrap) |
| Code de retour | `exit 0` succès / `1` erreur / `2` warning |
| Configuration externe | Tout dans `_config/E6-Config.psd1` |

## Logger

Niveaux : `INFO` | `OK` | `WARN` | `ERR` | `SKIP` | `STEP`

Sortie :
- **Console** : coloration selon le niveau (Cyan/Green/Yellow/Red/DarkGray/Cyan)
- **Fichier local** : `Logs/<script>_<yyyy-MM-dd_HH-mm-ss>.log` (UTF-8)
- **Télémétrie centralisée** : `\\SRV-BCK-01\Logs$\<hostname>\` (activée par défaut)

## Convention de nommage

| Type | Convention | Exemple |
|---|---|---|
| Scripts | `<NN>-<phase>_<Action>.ps1` | `01-bootstrap_AD-Structure.ps1` |
| Fonctions | `<Verbe>-Yanix<Substantif>` | `New-YanixOU`, `Test-YanixIsAdmin` |
| Variables script | `$script:Nom` | `$script:YanixContext` |
| Paramètres | PascalCase en anglais | `-Prenom`, `-DryRun`, `-Force` |

## Phases d'exécution

| Numéro | Phase | Quand l'exécuter |
|---|---|---|
| 01-09 | **Bootstrap** | Une seule fois, lors du déploiement initial |
| 10-19 | **Ops** | Quotidien / à la demande (onboarding, reset, etc.) |
| 20-29 | **Maintenance** | Périodique (audits, cleanup mensuel) |

## Patron de script type

Pour ajouter un nouveau script, suivre ce squelette :

```powershell
[CmdletBinding(SupportsShouldProcess)]
param([switch]$DryRun)

# 1. Charger la bibliothèque
. $PSScriptRoot\_common\Common.ps1
. $PSScriptRoot\_common\AD-Helpers.ps1

# 2. Initialiser le contexte
Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# 3. Pre-flight checks
Test-YanixPrerequis -Required Admin, AD -Stop
$config = Get-YanixConfig

# 4. Actions métier (idempotentes, DryRun-aware)
Write-YanixLog STEP "=== Mon action ==="
if ($script:YanixContext.DryRun) {
    Write-YanixLog INFO "DRY-RUN : ..."
} else {
    # ... action réelle ...
}

# 5. Test post-deploiement (optionnel, recommandé pour bootstrap)
function Test-MonScript { ... }
if ($config.Tests.ActiverApresExecution -and -not $script:YanixContext.DryRun) {
    Test-MonScript | Out-Null
}

# 6. Récap + télémétrie + exit code
exit (Show-YanixRecap)
```

## Bibliothèque commune — fonctions principales

### Common.ps1
- `Get-YanixConfig` — charge `E6-Config.psd1`
- `Initialize-YanixContexte` — init logger + dossiers + banner
- `Write-YanixLog` — log INFO/OK/WARN/ERR/SKIP/STEP
- `Show-YanixBanner`, `Show-YanixRecap`
- `Invoke-YanixTelemetrie` — copie log vers BCK-01
- `Test-YanixIsAdmin`, `Test-YanixIsDomainAdmin`
- `Test-YanixModule`, `Test-YanixConnectivite`, `Test-YanixRemoting`
- `Test-YanixPrerequis` — batch de pre-flight checks
- `Invoke-YanixAction` — wrapper avec skip/dryrun/try-catch

### AD-Helpers.ps1
- `Test-YanixOU`, `Test-YanixGroupe`, `Test-YanixUtilisateur`, `Test-YanixOrdinateur`
- `New-YanixOU`, `New-YanixGroupe`, `Add-YanixGroupeMembre`
- `Get-YanixDCActif`, `Test-YanixReplicationDC`
- `ConvertTo-YanixSansAccents`, `Get-YanixSamAccountName`
- `New-YanixMotDePasseAnssi` — mdp 15 chars conforme ANSSI

### FS-Helpers.ps1
- `Test-YanixPartage`, `New-YanixPartage`
- `Set-YanixAclAGDLP` — ACL stricte AGDLP
- `Test-YanixAclConformeAGDLP`
- `New-YanixHomeDirectory` — home avec ACL stricte

## Sources de référence

- **Microsoft Learn — Active Directory Best Practices** : https://learn.microsoft.com/windows-server/identity/
- **ANSSI PA-022** — Recommandations de configuration d'un système Windows
- **ANSSI Tier model** — Administration sécurisée des SI
- **Microsoft Approved Verbs** — `Get-Verb` (verbes PowerShell standardisés)
- **AGDLP** — Account → Global → Domain Local → Permission (modèle de référence Microsoft)
