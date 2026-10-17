# Portail : les sessions

Portail est votre bureau sur la plateforme scientifique CANFAR : la charge de la plateforme, votre
stockage, vos sessions (calepins Jupyter, bureaux, CARTA, Firefly et applications contribuées), les
images qu’elles exécutent, et vos tâches en lot. Il faut être connecté. Ouvrez-le depuis sa tuile de
l’accueil, ou par **Aller ▸ Portail** (⌘5).

![Portail](../images/fr/06-portal-sessions/portal.png)

1. **Charge de la plate-forme** : la charge des processeurs, de la mémoire et des GPU de CANFAR en ce moment.
2. **Lancer la session** : le formulaire de lancement.
3. **Ouvrir** : une session en cours, dans votre navigateur.
4. **Renouveler** : prolonge la durée de vie d’une session.
5. **Événements** : ce que la plateforme a fait de la session, et ses journaux.
6. **Supprimer** : arrête la session et la supprime.
7. **Images CANFAR** : les images que vous pouvez lancer.
8. **Lancements récents** : ce que vous avez lancé, à relancer.

## Les cartes du haut

Chaque carte a le même bouton d’actualisation en haut à droite. Il devient une petite roue pendant que
la carte se recharge, et le pied de la carte dit quand elle a été mise à jour, comme **Mis à jour à
16:04:05**. Pendant qu’une carte se recharge, ses chiffres restent, estompés, et rien n’y bouge.

- **Charge de la plate-forme** : trois anneaux, **CPU**, **Mémoire** et **GPU**, chacun avec la part
  utilisée au centre, comme **39 %**, et en dessous ce qui est libre, comme **1 836 sur 3 000 cœurs
  libres**. Un anneau passe à l’orange au-delà de 70 % et au rouge au-delà de 90 %. **GPU** reste gris,
  avec **Non communiqué**, tant que CANFAR ne communique pas ses GPU ; il se remplit tout seul à
  l’actualisation suivante dès que CANFAR le fait. Pendant l’actualisation, chaque anneau tourne, avec
  une petite roue à la place de son pourcentage. Sous les anneaux, combien d’instances tournent.
- **Stockage** : la part de votre quota VOSpace utilisée (**Utilisé**, **Utilisation**, **Quota**). Il
  avertit **Stockage presque plein**. Son bouton d’actualisation relit le quota, après un envoi ou une
  suppression. Voir [Stockage](09-storage.md).
- **Tâches en lot** : combien de vos tâches sont en cours, en attente, terminées ou en échec, actualisé
  toutes les 45 secondes ; le pied de la carte dit quand vient la prochaine (**· prochaine dans
  32 s**). **Tâches et historique…** les ouvre : voir [Tâches en lot](07-batch-jobs.md).

Quand une carte ne peut pas se charger, elle dit pourquoi, avec **Réessayer** et un bouton qui copie le
message ; ce qu’elle montrait reste.

## Vos sessions

**Sessions actives** liste vos sessions, actualisées d’elles-mêmes (un compte à rebours mène à la
prochaine actualisation), ou tout de suite avec son bouton d’actualisation. Chaque carte montre :

- le nom de la session, son image, et son état (en attente, en cours, en échec…) ;
- quand elle a démarré et quand elle expire ;
- son processeur (**UC**) et sa RAM, et le GPU quand elle en a un : ce qui lui a été attribué, ou,
  pour une session flexible (**FLEX**), ce qu’elle utilise en ce moment (**utilisé**).

Ses boutons :

- **Ouvrir** ouvre la session dans votre navigateur.
- **Renouveler** prolonge sa durée de vie.
- **Événements** montre **Événements / Journaux** : les événements de la plateforme pour la session
  (ordonnancement, téléchargement de l’image, erreurs), et les **Journaux** du conteneur, avec
  **Copier**.
- **Supprimer** arrête la session et la supprime, après confirmation. Le travail non enregistré qu’elle
  contient est perdu.

Verbinal envoie une notification quand une session que vous avez lancée est prête, ou n’a pas pu
démarrer.

![Événements / Journaux](../images/fr/06-portal-sessions/session-events.png)

## Lancer une session

![Le formulaire de lancement](../images/fr/06-portal-sessions/launch-form.png)

1. Cliquez sur **Lancer la session**.
2. **Type de session** : Notebook, Desktop, CARTA, Firefly ou Contributed.
3. **Projet** et **Image du conteneur** : l’image à exécuter. Une longue liste s’ouvre avec un champ
   **Rechercher** pour la restreindre.
4. **Nom de la session** : Verbinal en propose un ; le bouton à côté en propose un autre.
5. **Ressources** : **Flexible**, où CANFAR donne à la session ce qu’il peut, ou **Fixe**, où vous
   choisissez les **Cœurs CPU** et la **Mémoire (Go)**. **Utiliser un GPU** demande un GPU pour la
   session et passe les ressources à **Fixe** ; il est grisé tant que CANFAR n’offre pas de GPU.
6. Cliquez sur **Lancer la session**.

Une fenêtre de progression suit le lancement et se ferme d’elle-même quand la session tourne ; la
session apparaît alors dans **Sessions actives**. En cas d’échec, la fenêtre dit pourquoi.

- L’étoile à côté d’un champ fait de sa valeur votre valeur par défaut pour le prochain lancement
  (**Définir comme … par défaut**) ; cliquez de nouveau pour l’effacer. **Réglages ▸ Portail** contient
  les mêmes valeurs par défaut.
- Le formulaire dit quand la liste des images a été récupérée (**Images mises en cache** …) ;
  **Actualiser** la récupère à nouveau.
- La loupe à côté de **Image du conteneur** ouvre la [Découverte d’images](08-image-discovery.md), pour
  trouver une image d’après ce qu’elle contient.
- Si un lancement devait remplacer une entrée des **Lancements récents** de même nom, Verbinal
  demande : **Remplacer** ou **Ignorer**.

### Une image personnalisée

![L’onglet Avancé](../images/fr/06-portal-sessions/launch-form-advanced.png)

L’onglet **Avancé** lance une image par son nom complet : l’**URL de l'image du conteneur**, et, pour
une image privée, son **Authentification du registre (facultatif)** (**Nom d'utilisateur** et
**Secret**). Ses ressources sont celles de l’onglet Standard, sauf les GPU : avec **Fixe**, son nombre de
**GPU** parcourt les nombres que CANFAR propose, comme pour une tâche en lot, là où Standard a **Utiliser
un GPU**. Il est grisé tant que CANFAR n’en propose pas. Puis **Lancer (image personnalisée)**.

L’onglet **Headless** lance des tâches en lot : voir [Tâches en lot](07-batch-jobs.md).

## Images

La carte **Images CANFAR** liste les images que vous pouvez lancer, par type de session : les puces du
haut (**Default**, **Popular**, **Ajoutées**, puis chaque type) les filtrent, avec leur nombre, et
**Filtrer…** en trouve une par son nom.

- Le bouton de rechargement, en haut à droite, récupère de nouveau le catalogue. S’il ne peut pas être
  chargé, la carte dit pourquoi en bas, avec **Réessayer**, et garde les images qu’elle avait.
- Une étoile marque votre image par défaut pour ce type de session, et une horloge celle que vous avez
  lancée récemment.
- Les boutons d’une ligne utilisent l’image dans le formulaire de lancement, ou montrent ce qu’elle
  contient.
- Le compte en haut à droite (… **sur** … **découvertes**) et **Plus d'inspection…** ouvrent la
  [Découverte d’images](08-image-discovery.md) ; **Chercher dans le registre…** ajoute une image que le
  catalogue ne liste pas.

## Lancements récents

**Lancements récents** garde ce que vous avez lancé : nom, type, image, ressources et date.
**Relancer** le relance tel quel ; **Retirer** le retire de la liste ; **Filtrer…** en trouve un ;
**Effacer** vide la liste.

## Ce qu’un assistant peut faire ici

Il peut lire la charge de la plateforme, vos sessions avec leurs événements et journaux, les images et
vos lancements récents ; ouvrir le formulaire de lancement et le remplir ; lancer, renouveler et ouvrir
des sessions ; et les supprimer, ce qui vous attend sauf si vous l’avez autorisé. Il ne lance qu’avec
une image de la liste.
