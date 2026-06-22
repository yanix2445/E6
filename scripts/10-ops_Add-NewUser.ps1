<#
.SYNOPSIS
    Onboarding atomique d'un utilisateur AD - Add-NewUser v3.0
    Conforme cadre prod-ready E6 - ANSSI PA-022 + Microsoft New-ADUser

.DESCRIPTION
    Provisionnement complet et atomique d'un nouvel employe dans le SI :
      1. Pre-flight checks (Admin, Domain Admin, AD, FS-01)
      2. Mode interactif si parametres manquants (questions/reponses)
      3. Creation du compte AD avec attributs LDAP complets
      4. Ajout aux groupes metier (modele AGDLP : GG_<Service> + GG_TousSalaries)
      5. Creation du dossier home + ACL stricte (via Remoting sur SRV-FS-01)
      6. Verification post-creation (compte, attributs, dossier, groupes)
      7. Logging structure (lib commune : fichier local + telemetrie centralisee)
      8. Fiche de bienvenue formatee pour l'employe

    Architecture : ceinture (script cree le dossier) + bretelles (GPO redirige sous-dossiers).
    Mappage des lecteurs au logon = GPO_Mappage_Lecteurs (independant de homeDirectory).
    Conformite RGPD : logs des actions, mot de passe non logge en clair.

.PARAMETER Prenom
    Prenom de l'employe. Accents/tirets/apostrophes acceptes (Edouard, Jean-Charles, O'Connor).

.PARAMETER Nom
    Nom de famille.

.PARAMETER Service
    Service metier (TAB-completion). Voir E6-Config.psd1 pour la liste.

.PARAMETER Titre
    Intitule de poste (optionnel).

.PARAMETER Manager
    sAMAccountName du manager hierarchique (optionnel).

.PARAMETER TypeContrat
    "CDI" (defaut) ou "CDD".

.PARAMETER DateExpiration
    Date de fin de contrat (CDD). Le compte sera desactive automatiquement par AD.

.PARAMETER MotDePasse
    Mot de passe initial explicite (optionnel).
    Priorite : -MotDePasse > -RandomPassword > defaut (depuis config).

.PARAMETER RandomPassword
    Genere un mdp aleatoire 15 chars conforme ANSSI.

.PARAMETER NoForceChange
    Desactive l'obligation de changer le mdp au 1er logon (deconseille ANSSI).

.PARAMETER DryRun
    Simulation sans modification.

.PARAMETER Interactive
    Force le mode interactif meme si parametres fournis.

.EXAMPLE
    .\10-ops_Add-NewUser.ps1
    Mode interactif complet (le script pose toutes les questions).

.EXAMPLE
    .\10-ops_Add-NewUser.ps1 -Prenom Marie -Nom Dupont -Service Marketing-Communication

.EXAMPLE
    .\10-ops_Add-NewUser.ps1 -Prenom Jean -Nom Martin -Service Developpement `
                             -Titre "Tech Lead" -Manager marie.dupont `
                             -TypeContrat CDD -DateExpiration "2027-06-30"

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 3.0 - 2026-06-22 (refonte cadre prod-ready)
    Conforme: ANSSI PA-022 (R.16, R.18, R.20, R.22), Microsoft New-ADUser
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$false)] [string]$Prenom,
    [Parameter(Mandatory=$false)] [string]$Nom,
    [Parameter(Mandatory=$false)] [string]$Service,
    [string]$Titre,
    [string]$Manager,
    [ValidateSet('CDI','CDD')] [string]$TypeContrat = 'CDI',
    [datetime]$DateExpiration,
    [string]$MotDePasse,
    [switch]$RandomPassword,
    [switch]$NoForceChange,
    [switch]$DryRun,
    [switch]$Interactive
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1
. $PSScriptRoot\_common\AD-Helpers.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# PRE-FLIGHT
# ============================================================================
Test-YanixPrerequis -Required Admin, DomainAdmin, AD, FS01 -Stop

$config = Get-YanixConfig

# Validation du service contre la liste de la config
$servicesValides = $config.ServicesMetier
if ($Service -and ($Service -notin $servicesValides)) {
    Write-YanixLog ERR "Service '$Service' invalide. Valeurs autorisees : $($servicesValides -join ', ')"
    exit (Show-YanixRecap)
}

# Variables locales
$fsServer       = $config.Serveurs.FS01.Hostname
$domain         = $config.Domain
$domainNetBIOS  = $config.DomainNetBIOS
$company        = $config.Company
$helpdesk       = $config.Contacts.Helpdesk
$ouUsersBase    = $config.OUs.Utilisateurs

# Mot de passe par defaut
$defaultPwd = $config.MotDePasse.DefautBienvenue

# ============================================================================
# MODE INTERACTIF (questions / reponses)
# ============================================================================

function Read-RequiredInput {
    param([string]$Prompt, [string]$Pattern = '.+', [string]$ErrorMsg = 'Valeur invalide')
    while ($true) {
        $val = Read-Host $Prompt
        if ($val -match $Pattern) { return $val.Trim() }
        Write-Host "  > $ErrorMsg" -ForegroundColor Red
    }
}

function Read-ServiceChoice {
    Write-Host "`nServices disponibles :" -ForegroundColor Cyan
    for ($i = 0; $i -lt $servicesValides.Count; $i++) {
        Write-Host ('  {0,2}. {1}' -f ($i + 1), $servicesValides[$i])
    }
    while ($true) {
        $val = Read-Host 'Numero du service'
        if ($val -match '^\d+$' -and [int]$val -ge 1 -and [int]$val -le $servicesValides.Count) {
            return $servicesValides[[int]$val - 1]
        }
        Write-Host '  > Numero invalide' -ForegroundColor Red
    }
}

function Invoke-InteractiveMode {
    Write-YanixLog STEP '=== Mode interactif ==='

    if (-not $script:Prenom) {
        $script:Prenom = Read-RequiredInput -Prompt 'Prenom' `
            -Pattern "^[\p{L}\-' ]{1,40}$" `
            -ErrorMsg 'Lettres/tirets/apostrophes uniquement (max 40 chars)'
    }
    if (-not $script:Nom) {
        $script:Nom = Read-RequiredInput -Prompt 'Nom' `
            -Pattern "^[\p{L}\-' ]{1,40}$" `
            -ErrorMsg 'Lettres/tirets/apostrophes uniquement (max 40 chars)'
    }
    if (-not $script:Service) {
        $script:Service = Read-ServiceChoice
    }
    if (-not $script:Titre) {
        $t = Read-Host 'Titre/poste (optionnel, Entree pour passer)'
        if ($t) { $script:Titre = $t.Trim() }
    }
    if (-not $script:Manager) {
        $m = Read-Host 'sAMAccountName du manager (optionnel, Entree pour passer)'
        if ($m) { $script:Manager = $m.Trim() }
    }
    if (-not $script:DateExpiration -and $script:TypeContrat -eq 'CDD') {
        $d = Read-Host "Date d'expiration CDD (yyyy-MM-dd, Entree pour passer)"
        if ($d) {
            try { $script:DateExpiration = [datetime]::ParseExact($d, 'yyyy-MM-dd', $null) }
            catch { Write-Host '  > Format invalide, ignore' -ForegroundColor Yellow }
        }
    }
}

# Declencher le mode interactif si parametres manquants
if ($Interactive -or -not $Prenom -or -not $Nom -or -not $Service) {
    Invoke-InteractiveMode
}

if (-not $Prenom -or -not $Nom -or -not $Service) {
    Write-YanixLog ERR 'Parametres requis manquants apres mode interactif'
    exit (Show-YanixRecap)
}

# ============================================================================
# CONSTRUCTION DE L'IDENTITE
# ============================================================================

$prenomClean = (ConvertTo-YanixSansAccents $Prenom) -replace "[^A-Za-z\- ]", ''
$nomClean    = (ConvertTo-YanixSansAccents $Nom)    -replace "[^A-Za-z\- ]", ''
$sam         = Get-YanixSamAccountName -Prenom $Prenom -Nom $Nom

$identity = [PSCustomObject]@{
    Sam         = $sam
    PrenomClean = $prenomClean.Trim()
    NomClean    = $nomClean.Trim()
    DisplayName = "$($prenomClean.Trim()) $($nomClean.Trim())"
    Upn         = "$sam@$domain"
    Mail        = "$sam@$domain"
    HomePath    = "\\$fsServer\Users`$\$sam"
    OuPath      = "OU=$Service,$ouUsersBase"
}

# Determination du mot de passe
$pwdMode = 'defaut'
$pwd     = $defaultPwd
if ($MotDePasse) {
    $pwd = $MotDePasse
    $pwdMode = 'explicite'
} elseif ($RandomPassword) {
    $pwd = New-YanixMotDePasseAnssi -Longueur 15
    $pwdMode = 'aleatoire'
}
$pwdSecure = ConvertTo-SecureString $pwd -AsPlainText -Force

# ============================================================================
# RECAP AVANT ACTION
# ============================================================================
Write-YanixLog STEP "=== Recap de l'operation ==="
Write-YanixLog INFO "  SamAccountName  : $($identity.Sam)"
Write-YanixLog INFO "  DisplayName     : $($identity.DisplayName)"
Write-YanixLog INFO "  UPN             : $($identity.Upn)"
Write-YanixLog INFO "  OU destination  : $($identity.OuPath)"
Write-YanixLog INFO "  Home (H:)       : $($identity.HomePath)"
Write-YanixLog INFO "  Groupes         : GG_$Service + GG_TousSalaries"
Write-YanixLog INFO "  Type contrat    : $TypeContrat"
if ($DateExpiration) {
    Write-YanixLog INFO "  Fin contrat     : $($DateExpiration.ToString('yyyy-MM-dd'))"
}
Write-YanixLog INFO "  Mot de passe    : (mode '$pwdMode', affiche en fin)"
Write-YanixLog INFO "  Force change    : $(-not $NoForceChange)"

# ============================================================================
# VERIFICATIONS PRE-CREATION
# ============================================================================

if (Test-YanixUtilisateur -SamAccountName $identity.Sam) {
    Write-YanixLog ERR "Le user '$($identity.Sam)' existe deja. Onboarding annule."
    exit (Show-YanixRecap)
}
if (-not (Test-YanixOU -DistinguishedName $identity.OuPath)) {
    Write-YanixLog ERR "OU cible introuvable : $($identity.OuPath)"
    exit (Show-YanixRecap)
}
Write-YanixLog OK "Le user n'existe pas, OU cible OK - pret pour creation"

if ($script:YanixContext.DryRun) {
    Write-YanixLog INFO "DRY-RUN : aucune modification effectuee. Compte $($identity.Sam) NON cree."
    exit (Show-YanixRecap)
}

# ============================================================================
# EXECUTION ATOMIQUE
# ============================================================================
Write-YanixLog STEP '=== Execution atomique ==='

# 1. Creation du user AD
try {
    $params = @{
        Name                  = $identity.Sam
        SamAccountName        = $identity.Sam
        UserPrincipalName     = $identity.Upn
        GivenName             = $identity.PrenomClean
        Surname               = $identity.NomClean
        DisplayName           = $identity.DisplayName
        EmailAddress          = $identity.Mail
        Path                  = $identity.OuPath
        AccountPassword       = $pwdSecure
        Enabled               = $true
        ChangePasswordAtLogon = (-not $NoForceChange)
        HomeDirectory         = $identity.HomePath
        HomeDrive             = 'H:'
        Company               = $company
        Department            = $Service
    }
    if ($Titre)   { $params.Title = $Titre }
    if ($Manager) {
        try {
            $mgrDn = (Get-ADUser -Filter "SamAccountName -eq '$Manager'" -ErrorAction Stop).DistinguishedName
            if ($mgrDn) { $params.Manager = $mgrDn }
        } catch {
            Write-YanixLog WARN "Manager '$Manager' introuvable, attribut Manager non defini"
        }
    }
    if ($DateExpiration) { $params.AccountExpirationDate = $DateExpiration }

    New-ADUser @params -ErrorAction Stop
    Write-YanixLog OK "Compte AD cree : $($identity.Sam) dans $($identity.OuPath)"
} catch {
    Write-YanixLog ERR "Echec creation compte AD : $($_.Exception.Message)"
    exit (Show-YanixRecap)
}

# 2. Ajout aux groupes
$groupes = @("GG_$Service", 'GG_TousSalaries')
foreach ($g in $groupes) {
    Add-YanixGroupeMembre -GroupName $g -MemberName $identity.Sam
}

# 3. Creation du dossier home (via Remoting sur FS-01)
$homeBlock = {
    param($sam, $netbios)
    $homePath = "D:\Partages\Users\$sam"
    if (Test-Path $homePath) { return "SKIP: $homePath deja present" }

    $domainSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.AccountDomainSid).Value
    $domainAdmins = (New-Object System.Security.Principal.SecurityIdentifier "$domainSid-512").Translate([System.Security.Principal.NTAccount]).Value
    $localSystem  = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18').Translate([System.Security.Principal.NTAccount]).Value

    New-Item -Path $homePath -ItemType Directory -Force | Out-Null

    $acl = Get-Acl $homePath
    $acl.SetAccessRuleProtection($true, $false)
    @($acl.Access | Where-Object { -not $_.IsInherited }) |
        ForEach-Object { [void]$acl.RemoveAccessRule($_) }

    $rules = @(
        @{ Id = $domainAdmins;   Rights = 'FullControl' }
        @{ Id = $localSystem;    Rights = 'FullControl' }
        @{ Id = "$netbios\$sam"; Rights = 'Modify, Synchronize' }
    )
    foreach ($r in $rules) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $r.Id, $r.Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $homePath -AclObject $acl
    return "OK: $homePath cree avec ACL stricte"
}

try {
    $r = Invoke-Command -ComputerName $fsServer -ScriptBlock $homeBlock `
                        -ArgumentList $identity.Sam, $domainNetBIOS -ErrorAction Stop
    if ($r -like 'SKIP:*') { Write-YanixLog SKIP $r } else { Write-YanixLog OK $r }
} catch {
    Write-YanixLog ERR "Echec creation home : $($_.Exception.Message)"
}

# ============================================================================
# VERIFICATION POST-CREATION
# ============================================================================
Write-YanixLog STEP '=== Verification post-creation ==='

$u = Get-ADUser -Identity $identity.Sam -Properties HomeDirectory, HomeDrive, Department -ErrorAction SilentlyContinue
if (-not $u) {
    Write-YanixLog ERR "User $($identity.Sam) introuvable apres creation"
} else {
    Write-YanixLog OK "User present : $($u.DistinguishedName)"
    if ($u.HomeDirectory -eq $identity.HomePath) { Write-YanixLog OK 'HomeDirectory correct' }
    else { Write-YanixLog WARN "HomeDirectory : $($u.HomeDirectory) (attendu : $($identity.HomePath))" }
    if ($u.Department -eq $Service) { Write-YanixLog OK 'Department correct' }
    else { Write-YanixLog WARN "Department : $($u.Department) (attendu : $Service)" }
}

# Dossier home physique
if (Test-Path "\\$fsServer\D$\Partages\Users\$($identity.Sam)") {
    Write-YanixLog OK "Dossier home present sur $fsServer"
} else {
    Write-YanixLog ERR "Dossier home absent sur $fsServer"
}

# Groupes
$userGroups = (Get-ADUser $identity.Sam -Properties MemberOf).MemberOf | ForEach-Object { (Get-ADGroup $_).Name }
foreach ($g in $groupes) {
    if ($userGroups -contains $g) { Write-YanixLog OK "Membre de $g" }
    else { Write-YanixLog ERR "PAS membre de $g" }
}

# ============================================================================
# FICHE DE BIENVENUE
# ============================================================================
$bar = '=' * 68
Write-Host ''
Write-Host $bar -ForegroundColor Green
Write-Host " FICHE DE BIENVENUE - $company" -ForegroundColor Green
Write-Host $bar -ForegroundColor Green
Write-Host ''
Write-Host "Bonjour $($identity.PrenomClean)," -ForegroundColor White
Write-Host "Bienvenue chez $company !"
Write-Host ''
Write-Host 'Voici vos identifiants :'
Write-Host ''
Write-Host "  Identifiant   : $($identity.Sam)" -ForegroundColor Yellow
Write-Host "  Mot de passe  : $pwd" -ForegroundColor Yellow
if (-not $NoForceChange) {
    Write-Host '  (a changer obligatoirement a la 1ere connexion)' -ForegroundColor Yellow
}
Write-Host "  Email         : $($identity.Mail)"
Write-Host "  Service       : $Service"
if ($Titre) { Write-Host "  Poste         : $Titre" }
Write-Host "  Type contrat  : $TypeContrat"
if ($DateExpiration) { Write-Host "  Fin contrat   : $($DateExpiration.ToString('yyyy-MM-dd'))" }
Write-Host '  Lecteur H:    : votre dossier personnel'
Write-Host ''
Write-Host "Helpdesk : $helpdesk"
Write-Host $bar -ForegroundColor Green

Write-YanixLog INFO "Mot de passe genere en mode '$pwdMode' (NON logge en clair pour RGPD)"

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
