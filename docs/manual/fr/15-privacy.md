# Confidentialité et vos données

Verbinal n’a pas de serveur à lui. Il ne collecte rien sur vous, n’envoie rien à son développeur, et n’a
ni statistiques d’usage, ni pistage, ni publicité. Vos données restent sur votre Mac, ou vont aux services
du CADC et de CANFAR que vous utilisez, en HTTPS.

## Ce qui est gardé sur votre Mac

| Quoi | Où |
|---|---|
| Votre session CADC, votre nom d’utilisateur et, avec **Se souvenir de moi**, votre mot de passe | Le trousseau macOS, sur ce Mac seulement |
| Les secrets de registre (Découverte d’images, Calcul IA) | Le trousseau macOS |
| Vos observations de Recherche, notes, étiquettes et notes de qualité ; requêtes enregistrées et recherches récentes ; signets FITS ; marques ; flux de travail ; l’historique des tâches en lot | Le dossier propre à Verbinal, en base de données et en fichiers |
| Les journaux de session des assistants | Le dossier propre à Verbinal, 10 jours et 10 Mo au plus |
| Les résultats de la Découverte d’images, la liste des images, le train de données, les adresses des services | Des caches dans le dossier propre à Verbinal |
| Vos réglages | Les préférences de Verbinal |
| Les fichiers téléchargés, figures et exportations | Où vous le choisissez, ou votre dossier Téléchargements |
| Les noms, collections et instruments de vos observations de Recherche | L’index Spotlight du Mac |

Le dossier propre à Verbinal se trouve dans son bac à sable :
`~/Library/Containers/com.codebg.Verbinal`. Rien de ce qu’il contient n’est partagé avec d’autres apps.

## Ce qui quitte votre Mac, et vers qui

Verbinal ne s’adresse qu’à ceux-ci, et seulement quand vous (ou un assistant que vous avez autorisé) les
utilisez :

- **Les services du CADC et de CANFAR** : la connexion et votre compte, la plateforme scientifique
  (sessions, tâches en lot, images, charge de la plateforme), votre stockage VOSpace, l’archive
  (recherche, métadonnées, aperçus, téléchargements et découpes), le résolveur de noms, et le registre
  qui liste les services. Leurs adresses sont dans **Réglages ▸ Points d'accès**.
- **Le registre d’images de CANFAR** (`images.canfar.net`, ou celui que vous avez défini) : pour tester
  vos identifiants de registre et chercher des images.
- **VizieR au CDS** : seulement quand un assistant IA cherche dans un catalogue VizieR.

Les liens comme **Voir sur le CADC** ou **Signaler un problème** s’ouvrent dans votre navigateur, qui est
hors de Verbinal.

## Les assistants IA

Le serveur MCP est désactivé tant que vous n’activez pas **Autoriser les agents IA externes**, et seuls
les programmes de ce Mac peuvent le joindre. Un assistant que vous autorisez lit ce que ses outils
renvoient : vos observations, notes, sessions ou fichiers, selon ce que vous lui permettez. Ce qu’il envoie
à son propre service regarde vous et ce service. Le journal de session enregistre ce qu’il a fait, jamais
votre mot de passe. Voir [Travailler avec un assistant IA](12-ai-assistant.md#ce-qui-reste-privé).

## Supprimer vos données

- **Se déconnecter** retire votre session enregistrée et votre mot de passe du trousseau.
- Dans Recherche, **Supprimer le fichier…** supprime un fichier et **Supprimer** une observation ; vos
  notes sont gardées jusqu’à ce que vous les effaciez.
- **Effacer** vide les recherches récentes, les requêtes enregistrées, les lancements récents,
  l’historique des tâches en lot et la liste d’activité, chacun à sa place.
- Les **Réglages** vident les caches (**Portail ▸ Vider le cache**,
  **Découverte d'images ▸ Cache de découverte d'images**), retirent les secrets de registre
  (**Supprimer le secret**, **Réinitialiser**), et suppriment les journaux de session
  (**Agent IA ▸ Journaux de session**).
- Pour tout retirer, quittez Verbinal, mettez-le à la Corbeille, et supprimez son dossier
  `~/Library/Containers/com.codebg.Verbinal`.

Vos fichiers VOSpace sont sur CANFAR, pas sur votre Mac : ils restent jusqu’à ce que vous les supprimiez
dans [Stockage](09-storage.md).
