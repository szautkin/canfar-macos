# Réglages

Ouvrez les réglages avec ⌘, ou le bouton en forme d’engrenage de la barre d’outils. Ils comptent huit
sections ; chacune est décrite ici avec tous ses réglages. Les réglages sont à vous seul : un assistant
IA peut en lire certains, jamais les modifier.

## Général

![Réglages ▸ Général](../images/fr/14-settings/settings-general.png)

| Réglage | Ce qu’il fait |
|---|---|
| **Langue** | **Système** suit votre Mac ; ou choisissez **Anglais** ou **Français**. Verbinal affiche **Redémarrage requis** : cliquez sur **Redémarrer maintenant** pour l’appliquer. |
| **Téléchargements** ▸ **Dossier de téléchargement** | Où Verbinal enregistre ce que vous téléchargez : une observation et ses fichiers, les découpes, les figures, les exports. **Téléchargements** jusqu’à ce que vous le changiez avec **Modifier…** ; **Afficher dans le Finder** le montre ; **Utiliser Téléchargements** y revient. Quand le dossier choisi n’est pas là (un disque non branché), les téléchargements vont dans Téléchargements, et ce réglage le dit. |

## Portail

![Réglages ▸ Portail](../images/fr/14-settings/settings-portal.png)

Les valeurs avec lesquelles s’ouvre le formulaire de lancement (voir
[Portail : les sessions](06-portal-sessions.md)). Connectez-vous pour les changer ; elles sont gardées
pour votre compte sur ce Mac.

| Réglage | Ce qu’il fait |
|---|---|
| **Valeurs par défaut** ▸ **Type de session** | Le type sur lequel s’ouvre le formulaire, parmi ceux que CANFAR propose (Notebook, Desktop, etc.), ou **Aucune valeur par défaut**. |
| **Valeurs par défaut** ▸ **Projet** | Le projet d’images sur lequel s’ouvre le formulaire, ou **Aucune valeur par défaut**. |
| **Valeurs par défaut** ▸ **Image du conteneur** | L’image que le formulaire sélectionne, ou **Aucune valeur par défaut**. |
| **Effacer toutes les valeurs par défaut** | Oublie les valeurs ci-dessus pour ce compte. |
| **Valeurs par défaut des ressources** ▸ **Préréglage** | **Aucun**, **Flexible** ou **Fixe**. Avec **Fixe**, choisissez **Cœurs** et **RAM (Go)**, et **GPU** quand CANFAR en propose. Les tailles proposées viennent de CANFAR. |
| **Cache des images** | Quand la liste des images a été récupérée (**En cache :** …). **Actualiser maintenant** récupère à nouveau le catalogue d’images ; **Vider le cache** le supprime, et il est récupéré à la prochaine ouverture de Portail. |

## Agent IA

![Réglages ▸ Agent IA](../images/fr/14-settings/settings-agent.png)

Comment les assistants IA joignent Verbinal et ce qu’ils peuvent faire.
[Travailler avec un assistant IA](12-ai-assistant.md) explique chaque partie.

| Réglage | Ce qu’il fait |
|---|---|
| **Serveur MCP** ▸ **Autoriser les agents IA externes** | Désactivé tant que vous ne l’activez pas. Activé, il démarre le serveur MCP local ; la ligne en dessous indique **À l'écoute**, et où. |
| **Ce qu’un assistant peut faire sans demander** | Pour chaque type de modification, **Autorisé** ou **Me demander**. **Les consignes données à chaque assistant** est sur **Demande toujours**. |
| **Ce qui supprime, remplace ou arrête** | De même, pour les types qui suppriment ou arrêtent quelque chose. **Rétablir les valeurs par défaut** remet chaque type. |
| **Autonomie** ▸ **Suivre l'activité de l'agent** | La fenêtre va là où la modification d’un assistant se voit. Activé. |
| **Autonomie** ▸ **Afficher la bannière d’activité** | Une bannière en haut de la fenêtre pendant qu’un assistant travaille. Activé. |
| **Autonomie** ▸ **Jouer un son quand un agent commence et s'arrête** | Désactivé. |
| **Diagnostic** | Combien d’assistants sont connectés, et combien d’outils sont enregistrés. |
| **Historique d'activité** | Un court résumé de chaque modification et de chaque vue faite par un assistant ; **Effacer** le vide. |
| **Activité récente** | Les cinq derniers appels : ce que chacun était et comment il a fini, jamais ses arguments. |
| **Sessions** ▸ **Terminer une session inactive après** | Combien de temps une session autorisée dure sans appel : **15 minutes**, **1 heure** (par défaut), **4 heures**, **12 heures** ou **1 jour**. Une session continue quand Verbinal redémarre. |
| **Instructions de session** | Ce par quoi commence la fenêtre d’autorisation de chaque nouvelle session, jusqu’à 250 mots ; **Réinitialiser** rétablit celles de Verbinal. |
| **Journaux de session** ▸ **Afficher les journaux de session…** | Chaque session d’assistant, ce qui s’est passé et pourquoi ; **Terminer la session** met fin à une session autorisée. |

Les types et **Autonomie** s’affichent quand **Autoriser les agents IA externes** est activé, et les
sections de **Diagnostic** à **Activité récente** quand le serveur tourne.

## Découverte d'images

![Réglages ▸ Découverte d’images](../images/fr/14-settings/settings-imageDiscovery.png)

Ce dont la [Découverte d’images](08-image-discovery.md) a besoin pour regarder dans des images privées.

| Réglage | Ce qu’il fait |
|---|---|
| **Registre** ▸ **Hôte du registre** | Le registre de conteneurs auquel vos identifiants s’appliquent. Par défaut, celui de CANFAR (`images.canfar.net`) ; Docker Hub, Quay ou GHCR fonctionnent aussi, avec l’hôte qui correspond au nom de l’image. **Enregistrer**. |
| **Identifiants** ▸ **Nom d'utilisateur** | Votre nom d’utilisateur du registre, en général votre nom d’utilisateur CADC. **Enregistrer**. |
| **Identifiants** ▸ **Secret** | Votre secret de registre : pour celui de CANFAR, le **secret CLI** de votre profil Harbor, pas votre mot de passe CADC. **Enregistrer le secret** le garde dans le trousseau macOS ; il n’est plus jamais affiché, seulement remplacé ou supprimé (**Supprimer le secret**). |
| **Tester la connexion** | Vérifie les identifiants auprès du registre. **Connexion rejetée** signifie le plus souvent qu’un mot de passe CADC a été saisi au lieu du secret CLI Harbor. |
| **Image d'inspection** | L’image qui exécute les tâches de sonde. Laissez-la vide pour celle de Verbinal. |
| **Cache de découverte d'images** | Combien d’images ont été examinées. **Effacer** les oublie toutes ; les sondes en cours continuent. |
| **Réinitialiser** | Efface l’hôte du registre, le nom d’utilisateur, le secret et l’image d’inspection ; ce qui est en cache reste. |

## Calcul IA

![Réglages ▸ Calcul IA](../images/fr/14-settings/settings-aiCompute.png)

La session dans laquelle le [Calcul à distance](10-remote-compute.md) exécute le code.

| Réglage | Ce qu’il fait |
|---|---|
| **Calcul distant IA** ▸ **Image de calcul** | L’image de conteneur que le Calcul à distance lance comme session « contributed », par exemple `images.canfar.net/<projet>/verbinal-execution:<version>`. Elle doit être enregistrée dans le registre de CANFAR pour le type de session « contributed ». Vide, le Calcul à distance est désactivé. **Enregistrer**. |
| **Ressources de calcul** ▸ **Cœurs**, **RAM (Go)** | La taille de cette session. La plus petite démarre le plus vite ; les tailles proposées viennent de CANFAR. |
| **Registre** et **Identifiants** | Comme dans Découverte d’images : le registre d’où l’image de calcul est tirée, et votre nom d’utilisateur et votre secret pour lui. |
| **Réinitialiser** | Efface l’image de calcul, l’hôte du registre, le nom d’utilisateur et le secret. |

## Stockage

Ce que Verbinal garde dans votre stockage VOSpace, et comment cela reste pareil sur chaque appareil que
vous utilisez. Un manifeste dans votre stockage, `.verbinal/manifest.json`, dit quels types de données
de Verbinal vous y gardez et où ; chaque Verbinal où vous vous connectez le lit. Verbinal les synchronise
dès que vous vous connectez, discrètement, et ne supprime jamais rien. Connectez-vous pour voir cette
section. Seuls les comptes CANFAR ont un stockage : avec un compte qui n’en a pas, cette section le dit,
et votre travail reste sur ce Mac.

| Réglage | Ce qu’il fait |
|---|---|
| **Votre travail dans VOSpace** | Un interrupteur pour chaque partie de votre travail, chacun désactivé tant que vous ne l’activez pas : **Recherche** (les détails de vos observations, leurs notes, étiquettes et qualité, pas leurs fichiers), **Marques sur les images** et **Signets du ciel** (ceux des fichiers de Recherche ou de votre stockage), **Flux de travail**, **Requêtes enregistrées**, **Recherches récentes** (les 100 dernières), **Guides pour les assistants** (vos guides, vos descriptions des outils et vos consignes de session par défaut), **Historique du calcul à distance**, **Historique des tâches en lot**, **Les images que vous avez ajoutées**, **Lancements récents**, **Valeurs de lancement par défaut du Portail**, et **Résultats : téléchargements, découpes, exportations de recherche et figures** : chaque résultat que Verbinal garde sur ce Mac va aussi dans `Verbinal-Results` dans votre stockage, en arrière-plan, et attend d’y aller tant que votre stockage est injoignable. Ce que vous activez est gardé dans votre stockage, dans `.verbinal`, et est pareil sur chaque appareil où vous vous connectez. Un choix fait ici vaut pour tous les appareils ; désactivé, les fichiers restent dans votre stockage. Chaque partie dit quand elle attend sa première synchronisation, quand elle se synchronise, ou pourquoi elle n’a pas pu. Rien ne bouge tant que tout le monde peut lire votre dossier `.verbinal` : ce réglage le dit jusqu’à ce que vous le rendiez privé dans [Stockage](09-storage.md#les-fichiers-qui-ne-devraient-pas-être-publics). Les connexions, ce que les assistants peuvent faire, les journaux de session et les fichiers de ce Mac n’en sortent jamais. |
| **Les données de Verbinal dans votre stockage** | Ce que Verbinal y garde de toute façon : **Listes de paquets des images**, **Exécutions du calcul à distance**, **Scripts des tâches en lot**, **Exportations**. Pour chacun, son dossier, combien d’éléments et leur taille, et ce que la dernière synchronisation a apporté sur ce Mac ; **Pas gardé dans votre stockage** quand le manifeste ne le déclare pas. **Afficher dans Stockage** ouvre son dossier. |
| **Synchroniser maintenant** | Synchronise aussitôt ; à côté, quand a eu lieu la dernière synchronisation. Une synchronisation qui a échoué dit pourquoi, et la suivante est tentée plus tard. |

Quand deux appareils ont modifié la même chose avant de se synchroniser, la modification la plus
récente l’emporte, et celle qu’elle remplace est gardée sur le Mac où elle a été faite.

## Clients MCP

![Réglages ▸ Clients MCP](../images/fr/14-settings/settings-mcpClients.png)

Comment chaque programme assistant joint Verbinal.

| Réglage | Ce qu’il fait |
|---|---|
| **État** | Si le serveur est à l’écoute ; il s’active et se désactive dans Agent IA. **Revérifier** le relit. |
| **Guide IA** ▸ **Afficher le Guide IA sur l'écran d'accueil** | Affiche ou masque la tuile Guide IA de l’accueil. Vos guides restent en vigueur dans les deux cas. |
| **Diagnostic** | Vérifie chaque maillon entre un assistant et Verbinal quand vous ouvrez l’onglet, chacun avec une réparation quand il y en a une. |
| **Autotest du serveur MCP** | **Lancer la vérification du serveur MCP** vérifie que le serveur répond. La preuve finale est de redémarrer votre client et d’y voir les outils de Verbinal. |
| **Configuration de Claude Desktop** | **Configurer Claude Desktop** ajoute Verbinal à la configuration de Claude Desktop en un clic. **Autoriser l’accès…**, **Mettre à jour la configuration**, **Copier l'extrait**, **Afficher la config** et **Ouvrir Claude** le font à la main. Redémarrez ensuite Claude Desktop. |
| **Claude Code** | Si Claude Code est installé. **Copier la commande** copie la commande `claude mcp add` pour ce Mac ; **Copier l'extrait JSON** copie l’entrée à coller dans `~/.claude.json`. |

## Points d'accès

![Réglages ▸ Points d’accès](../images/fr/14-settings/settings-endpoints.png)

Les adresses des services du CADC et de CANFAR auxquels Verbinal s’adresse. Vous avez rarement besoin
de les changer. Certains de leurs noms restent en anglais dans l’app.

| Réglage | Ce qu’il fait |
|---|---|
| **Registre IVOA** ▸ **IVOA registry (reg)** | Où Verbinal trouve les autres services. Il revérifie chaque jour ; **Actualiser maintenant** le fait tout de suite, et la ligne en dessous dit combien de services il a trouvés, et quand. |
| **Authentication** | **Login (CADC AC)** et **Account (Science Platform AC)** : la connexion, et votre compte de la plateforme. |
| **Science Platform** | **Science Platform (Skaha)**, qui exécute sessions et tâches, et **Storage (VOSpace nodes)**. |
| **Archive & Data** | **Archive (TAP / DataLink)**, pour la recherche, les métadonnées et les téléchargements, et **External web (browser)**. |
| **Tout réinitialiser aux valeurs par défaut** | Retire toutes les adresses que vous avez saisies. |
| **Tester les connexions** | Demande à chaque service s’il est disponible, et à quelle vitesse il répond. |

Chaque adresse montre d’où vient sa valeur : **Default** (par défaut), **Resolved** (du registre), ou
celle que vous avez saisie, qui l’emporte toujours ; **Effacer le remplacement** retire la vôtre. Les
adresses s’appliquent au démarrage de Verbinal : après un changement, **Redémarrage requis** propose
**Redémarrer maintenant**.

## À propos

![Réglages ▸ À propos](../images/fr/14-settings/settings-about.png)

La version de Verbinal, et **Fonctionnalités…**, qui ouvre **Ce que Verbinal peut faire**.
