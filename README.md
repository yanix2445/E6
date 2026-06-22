# 🚀 Projet E6 — Infrastructure PME & Automatisation (BTS SIO SISR)

Bienvenue sur le dépôt de mon projet d'infrastructure système et réseau, réalisé dans le cadre de l'épreuve E6 du **BTS SIO (Option SISR)** à FÉNELON Sup Paris. 

Ce projet n'est pas qu'un simple exercice académique : c'est la simulation concrète, de bout en bout, du déploiement d'une infrastructure pour une PME du secteur numérique (**Yanix Labs**, ~150 collaborateurs). J'ai voulu concevoir un SI robuste, hautement disponible et sécurisé, en appliquant rigoureusement les bonnes pratiques de l'industrie (Microsoft, ANSSI, RGPD).

---

## 🎯 L'ambition du projet

L'objectif était de dépasser le stade de la simple "maquette qui marche" pour aller vers un véritable environnement de production. 
Le cahier des charges exigeait :
- Une **continuité de service** transparente pour l'utilisateur final en cas de crash matériel.
- Une **sécurité by design** : segmentation réseau, principe de moindre privilège, traçabilité.
- Une **automatisation poussée** via PowerShell pour éliminer les tâches chronophages et réduire l'erreur humaine.

## 🏗️ Architecture et Choix Techniques

L'ensemble de la maquette a été virtuellement déployé sur **VMware Fusion Pro** (MacBook Apple Silicon, ARM64), prouvant ainsi la viabilité technique des environnements virtuels modernes.

### 🛡️ Réseau & Pare-feu (OPNsense)
- Segmentation en **4 VLANs isolés** : Utilisateurs, Serveurs, Management et Sauvegarde.
- Filtrage strict inter-VLAN et NAT sortant.
- Distribution DHCP gérée par le backend moderne **Kea**.

### 🔑 Identité & Annuaire (Active Directory)
- **2 Contrôleurs de domaine redondés** (Windows Server 2025).
- Service **DHCP Failover** (LoadBalance 50/50) garantissant la continuité d'attribution des IP.
- Structure d'Unités d'Organisation (OU) calquée sur l'entreprise et sécurisation par Tier model.

### 📁 Serveurs de Fichiers & Modèle AGDLP
- **2 Serveurs de fichiers** miroir répliqués en temps réel via **DFS-R**.
- Accès transparent pour les utilisateurs via un espace de noms abstrait (**DFS-N**).
- Implémentation stricte du modèle de permissions **AGDLP** (Account > Global > Domain Local > Permission), permettant une gestion évolutive et sécurisée (45 groupes de sécurité créés).
- Mappage dynamique des lecteurs réseaux (GPO Drive Maps) avec ciblage (Item-Level Targeting).

### 💾 Plan de Sauvegarde Centralisé (PRA)
- Serveur de sauvegarde dédié sur un réseau isolé.
- Approche à 3 niveaux : Shadow Copies pour le self-service utilisateur (RPO 1h), Sauvegarde centralisée quotidienne (RPO 24h), et Snapshots complets des VMs.

---

## 💻 Les Scripts PowerShell : L'automatisation au cœur du SI

L'un des axes majeurs de ce projet a été l'industrialisation des processus via des scripts PowerShell **idempotents**, documentés et conformes aux prérequis de sécurité (PA-022 ANSSI).

Vous trouverez dans le dossier `scripts/` l'intégralité du code utilisé pour construire et administrer ce domaine :

- **`01-bootstrap_AD-Structure.ps1`** : Déploie toute l'arborescence Active Directory et les groupes AGDLP en une commande.
- **`14-ops_Add-NewUser.ps1`** : Un script de provisionnement utilisateur ultra-complet (350+ lignes) avec mode interactif. Il gère la création du compte, la normalisation des noms, la génération d'un mot de passe fort (normes ANSSI), l'affectation aux groupes, la création du dossier personnel (via PSRemoting) et génère même une fiche de bienvenue !
- **`backup-centralise.ps1`** : Un orchestrateur de sauvegarde qui déclenche et consolide les backups de tous les serveurs à distance.

---

## 📖 Pour aller plus loin

Je vous invite vivement à consulter les documents PDF présents dans le dossier `dossier-E6/` :
- **Dossier-E6-HARRAT-Yanis.pdf** : Le rapport technique complet et détaillé (captures d'écran, schémas, tests de bascule et de continuité de service).
- **Fiche-Descriptive-E6-HARRAT-Yanis.pdf** : La synthèse pédagogique de la réalisation.

---

## 💡 Bilan Personnel

Ce projet a été une formidable aventure d'apprentissage. Il m'a appris que la vraie résilience ne se décrète pas dans un schéma d'architecture : **elle se prouve en débranchant des câbles**. Analyser les logs, comprendre les délais de réplication DNS, ou gérer les subtilités du DHCP Failover face aux comportements des clients Windows m'ont forgé une solide expérience en troubleshooting.

N'hésitez pas à explorer le code, à lire le dossier, ou à me faire part de vos retours !

*— Yanis HARRAT* 👨‍💻
