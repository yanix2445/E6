<#
.SYNOPSIS
    Creation/MAJ d'un compte administrateur Tier 0 conforme ANSSI
    Conforme cadre prod-ready E6

.DESCRIPTION
    Provisionne ou met a jour un compte super-admin Tier 0 dans l'AD :
      1. Cree le compte dans OU=Comptes-Admin,OU=Administration,...
      2. Ajoute aux groupes Tier 0 (Domain Admins, Enterprise Admins, Schema Admins)
         via leurs SIDs well-known (langue-independant FR/EN/DE)
      3. Configure les flags : PasswordNeverExpires (Tier 0), Enabled

    Operation CRITIQUE : confirmation systematique requise sauf si -Force.
    Le compte cree est en Tier 0 = privileges maximaux sur la foret.

.PARAMETER Prenom
    Prenom de l'admin (obligatoire)

.PARAMETER Nom
    Nom de l'admin (obligatoire)

.PARAMETER MotDePasse
    Mot de passe initial (genere aleatoire si non fourni)

.PARAMETER Force
    Bypass la confirmation (USAGE AUTOMATISE UNIQUEMENT)

.PARAMETER DryRun
    Simulation sans creation

.EXAMPLE
    .\14-ops_Create-Admin-Account.ps1 -Prenom Yanis -Nom Harrat -DryRun

.EXAMPLE
    .\14-ops_Create-Admin-Account.ps1 -Prenom Sophie -Nom Martin
    Cree un compte sophie.martin.adm avec mdp ANSSI aleatoire

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : Execute sur SRV-DC-01 en Domain Admin existant
    Conforme: ANSSI PA-022 R.16 (compte admin nominatif separe du compte standard)
              ANSSI Tier model (compte Tier 0 = admins de la foret)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Prenom,
    [Parameter(Mandatory)][string]$Nom,
    [string]$MotDePasse,
    [switch]$Force,
    [switch]$DryRun
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
Test-YanixPrerequis -Required Admin, DomainAdmin, AD -Stop

$config = Get-YanixConfig
$ouAdmins = $config.OUs.Admins
$ouComptesAdmin = "OU=Comptes-Admin,$ouAdmins"

# Verifier l'OU cible existe
if (-not (Test-YanixOU -DistinguishedName $ouComptesAdmin)) {
    Write-YanixLog ERR "OU Tier 0 introuvable : $ouComptesAdmin"
    Write-YanixLog ERR "Lance d'abord : .\01-bootstrap_AD-Structure.ps1"
    exit (Show-YanixRecap)
}
Write-YanixLog OK "OU Tier 0 detectee : $ouComptesAdmin"

# ============================================================================
# CONSTRUCTION DE L'IDENTITE
# ============================================================================
$prenomClean = (ConvertTo-YanixSansAccents $Prenom) -replace "[^A-Za-z\- ]", ''
$nomClean    = (ConvertTo-YanixSansAccents $Nom)    -replace "[^A-Za-z\- ]", ''
$samBase     = Get-YanixSamAccountName -Prenom $Prenom -Nom $Nom
$sam         = "$samBase.adm"   # convention : suffixe .adm pour les comptes admin

if ($sam.Length -gt 20) {
    $sam = $sam.Substring(0, 20)
    Write-YanixLog WARN "sAMAccountName tronque a 20 chars : $sam"
}

$upn         = "$sam@$($config.Domain)"
$displayName = "$($prenomClean.Trim()) $($nomClean.Trim()) (Admin)"

# Mot de passe
$pwdMode = 'aleatoire'
$pwd = $MotDePasse
if (-not $pwd) {
    $pwd = New-YanixMotDePasseAnssi -Longueur 18   # plus long pour Tier 0
} else {
    $pwdMode = 'explicite'
}
$pwdSecure = ConvertTo-SecureString $pwd -AsPlainText -Force

# ============================================================================
# RECAP AVANT ACTION
# ============================================================================
Write-YanixLog STEP "=== Compte administrateur Tier 0 a creer/maj ==="
Write-YanixLog INFO "  Identite      : $($prenomClean.Trim()) $($nomClean.Trim())"
Write-YanixLog INFO "  sAMAccountName: $sam"
Write-YanixLog INFO "  UPN           : $upn"
Write-YanixLog INFO "  OU cible      : $ouComptesAdmin"
Write-YanixLog INFO "  Groupes Tier 0: Domain Admins, Enterprise Admins, Schema Admins"
Write-YanixLog INFO "  Password Mode : $pwdMode"
Write-YanixLog INFO "  Privileges    : MAXIMAUX SUR LA FORET (Tier 0)"

# ============================================================================
# CONFIRMATION (sauf -Force ou -DryRun)
# ============================================================================
if (-not $Force -and -not $script:YanixContext.DryRun) {
    Write-Host ''
    Write-Host 'OPERATION CRITIQUE : creation/modification d''un compte Tier 0' -ForegroundColor Red
    Write-Host 'Ce compte aura les privileges MAXIMAUX sur la foret AD.' -ForegroundColor Red
    Write-Host ''
    $rep = Read-Host "Taper 'CONFIRMER' pour proceder"
    if ($rep -ne 'CONFIRMER') {
        Write-YanixLog INFO 'Annulation par l''operateur'
        exit (Show-YanixRecap)
    }
}

if ($script:YanixContext.DryRun) {
    Write-YanixLog INFO 'DRY-RUN : compte NON cree ni modifie. Verification uniquement.'
    exit (Show-YanixRecap)
}

# ============================================================================
# CREATION / MAJ DU COMPTE
# ============================================================================
$existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue

if ($existing) {
    Write-YanixLog STEP "Compte $sam existe : MAJ (reset MDP + flags + OU)"
    try {
        Set-ADAccountPassword -Identity $existing -NewPassword $pwdSecure -Reset -ErrorAction Stop
        Set-ADUser -Identity $existing `
                   -Enabled $true `
                   -PasswordNeverExpires $true `
                   -CannotChangePassword $false `
                   -ChangePasswordAtLogon $false `
                   -UserPrincipalName $upn `
                   -GivenName $prenomClean.Trim() `
                   -Surname $nomClean.Trim() `
                   -DisplayName $displayName `
                   -ErrorAction Stop

        # Deplace dans la bonne OU si necessaire
        $currentParent = ($existing.DistinguishedName -split ',', 2)[1]
        if ($currentParent -ne $ouComptesAdmin) {
            Move-ADObject -Identity $existing.DistinguishedName -TargetPath $ouComptesAdmin -ErrorAction Stop
            Write-YanixLog OK "Compte deplace dans $ouComptesAdmin"
        }
        Write-YanixLog OK "Compte $sam mis a jour (mdp reset, flags Tier 0 appliques)"
    } catch {
        Write-YanixLog ERR "Echec MAJ compte : $($_.Exception.Message)"
        exit (Show-YanixRecap)
    }
} else {
    Write-YanixLog STEP "Compte $sam n'existe pas : creation"
    try {
        New-ADUser -Name $sam `
                   -SamAccountName $sam `
                   -UserPrincipalName $upn `
                   -GivenName $prenomClean.Trim() `
                   -Surname $nomClean.Trim() `
                   -DisplayName $displayName `
                   -Description "Compte administrateur Tier 0 - usage admin uniquement (cree $(Get-Date -Format 'yyyy-MM-dd'))" `
                   -Path $ouComptesAdmin `
                   -AccountPassword $pwdSecure `
                   -Enabled $true `
                   -PasswordNeverExpires $true `
                   -ChangePasswordAtLogon $false `
                   -ErrorAction Stop
        Write-YanixLog OK "Compte cree : $sam dans $ouComptesAdmin"
    } catch {
        Write-YanixLog ERR "Echec creation compte : $($_.Exception.Message)"
        exit (Show-YanixRecap)
    }
}

# ============================================================================
# AJOUT AUX GROUPES TIER 0 (via SIDs well-known)
# ============================================================================
Write-YanixLog STEP "Ajout aux groupes Tier 0 (via SIDs well-known, langue-independant)"

# RIDs des groupes admin built-in
$adminGroupRIDs = @(
    @{ Rid = 512; Nom = 'Domain Admins' }
    @{ Rid = 519; Nom = 'Enterprise Admins' }
    @{ Rid = 518; Nom = 'Schema Admins' }
)

$domainSID = (Get-ADDomain).DomainSID.Value

foreach ($g in $adminGroupRIDs) {
    $sid = "$domainSID-$($g.Rid)"
    try {
        $grp = Get-ADGroup -Identity $sid -ErrorAction Stop
        $membres = Get-ADGroupMember -Identity $grp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName
        if ($membres -contains $sam) {
            Write-YanixLog SKIP "Deja membre de '$($grp.Name)' (RID $($g.Rid))"
        } else {
            Add-ADGroupMember -Identity $grp -Members $sam -ErrorAction Stop
            Write-YanixLog OK "Ajoute au groupe '$($grp.Name)' (RID $($g.Rid))"
        }
    } catch {
        Write-YanixLog ERR "Echec groupe RID $($g.Rid) : $($_.Exception.Message)"
    }
}

# ============================================================================
# RECAPITULATIF FINAL + INFOS DE CONNEXION
# ============================================================================
Write-YanixLog STEP '=== Verification post-creation ==='

$u = Get-ADUser -Identity $sam -Properties MemberOf, Enabled, PasswordNeverExpires
Write-YanixLog OK "Compte : $($u.SamAccountName) ($($u.UserPrincipalName))"
Write-YanixLog OK "  DN          : $($u.DistinguishedName)"
Write-YanixLog OK "  Enabled     : $($u.Enabled)"
Write-YanixLog OK "  PwdNeverExp : $($u.PasswordNeverExpires)"
Write-YanixLog OK "Groupes :"
$u.MemberOf | ForEach-Object { Write-YanixLog OK "  - $((Get-ADGroup $_).Name)" }

# Affichage du mdp en console (UNE SEULE FOIS, non logge en clair)
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Red
Write-Host ' CREDENTIALS DU COMPTE TIER 0 - A NOTER MAINTENANT' -ForegroundColor Red
Write-Host ('=' * 60) -ForegroundColor Red
Write-Host "  sAMAccountName : $sam" -ForegroundColor Yellow
Write-Host "  UPN            : $upn" -ForegroundColor Yellow
Write-Host "  Mot de passe   : $pwd" -ForegroundColor Yellow
Write-Host "  Mode           : $pwdMode" -ForegroundColor Yellow
Write-Host ('=' * 60) -ForegroundColor Red
Write-Host '  Ce mdp ne sera plus AFFICHE. Stocker dans un coffre-fort (KeePass, Bitwarden)' -ForegroundColor Yellow
Write-Host '  Ne JAMAIS utiliser ce compte pour des taches non admin' -ForegroundColor Yellow
Write-Host '  Connexion : RDP sur un serveur uniquement (politique Tier 0)' -ForegroundColor Yellow

Write-YanixLog INFO "Mot de passe affiche en console (NON logge en clair pour RGPD/securite)"

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
