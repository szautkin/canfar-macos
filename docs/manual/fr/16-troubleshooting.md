# Dépannage

Quand quelque chose ne fonctionne pas, la barre d’activité au bas de la fenêtre est le premier endroit
où regarder : elle dit ce que fait Verbinal, ce qui a échoué et pourquoi. Cliquez dessus pour la liste
**Activité**.

## La connexion

- **La connexion est refusée.** Vérifiez votre nom d’utilisateur et votre mot de passe CADC sur le site
  du CADC. Verbinal se connecte avec votre compte CADC ; un secret de registre (Harbor) n’est pas votre
  mot de passe.
- **On vous demande sans cesse de vous reconnecter.** Cochez **Se souvenir de moi** en vous connectant :
  Verbinal vous reconnecte alors de lui-même quand votre session CADC expire.
- **Verbinal a démarré hors ligne.** Il attend le réseau et vérifie alors votre session ; les tuiles qui
  demandent un compte se déverrouillent d’elles-mêmes.

## Le CADC ou CANFAR est lent ou en panne

- Une recherche affiche **En attente du CADC** avec les secondes écoulées ; **Annuler** l’arrête, et vous
  pouvez réessayer plus tard.
- **Réglages ▸ Points d'accès ▸ Tester les connexions** demande à chaque service s’il répond, et à quelle
  vitesse.
- Si vous avez changé une adresse dans **Réglages ▸ Points d'accès**,
  **Tout réinitialiser aux valeurs par défaut** remet les adresses habituelles ; elles s’appliquent après
  un redémarrage.
- Si **Stockage** montre les fichiers d’un autre dossier que celui de son chemin, rouvrez Stockage (depuis
  l’accueil, ou ⌘6).

## Une session ne démarre pas

- Ouvrez ses **Événements** : ils disent si CANFAR attend de la place, ne peut pas tirer l’image, ou l’a
  arrêtée.
- **Charge de la plate-forme** montre à quel point CANFAR est occupé. Une taille **Fixe** attend que
  cette place se libère ; une taille plus petite, ou **Flexible**, démarre plus tôt.
- Une notification vous dit quand la session est prête, ou qu’elle n’a pas pu démarrer.

## Une tâche en lot attend ou échoue

- Une tâche attend **En attente** que CANFAR ait de la place pour sa taille ; une taille plus petite
  démarre plus tôt.
- **Afficher événements et journaux** sur la tâche dit pourquoi elle a échoué, et ce qu’elle a écrit.
- Une tâche que CANFAR a retirée est toujours dans **Historique**, avec la façon dont elle s’est terminée.

## Le Calcul à distance n’est pas prêt

**Pas prêt** signifie que la session existe mais que son image ne peut pas être tirée. Vérifiez, dans
**Réglages ▸ Calcul IA** : le nom de l’**Image de calcul**, que l’image est enregistrée pour le type de
session « contributed », et, pour une image privée, le **Nom d'utilisateur** et le **Secret** du
registre (**Tester la connexion**). Puis **Arrêter la session** et **Démarrer la session** de nouveau.
Voir [Calcul à distance](10-remote-compute.md).

## La Découverte d’images

Une sonde qui échoue dit pourquoi ; **Voir les journaux de la sonde** montre ce que la tâche de sonde a
écrit. Pour les images privées, définissez vos identifiants de registre dans
**Réglages ▸ Découverte d'images** et **Tester la connexion** : l’erreur la plus courante est le mot de
passe CADC à la place du secret CLI Harbor.

## Les visionneuses

- **« … n'est plus disponible »** : le fichier a été déplacé ou supprimé depuis son ouverture.
  Rouvrez-le depuis son nouvel emplacement.
- **WCS approximatif** : le fichier n’a pas de coordonnées célestes standard ; les positions sont
  estimées.
- **Visionneuse Cube, volume** : sur un Mac Intel, ou un Mac sans GPU adapté, une bannière dit pourquoi
  le volume ne peut pas être dessiné. Le mode Slice fonctionne toujours.
- **Visionneuse Cube, sonde de spectre** : un très gros cube est lu depuis le disque (**Streamed**), et
  sa sonde de spectre n’est pas disponible.

## Un assistant IA ne se connecte pas

1. Verbinal est-il ouvert ? La connexion de l’assistant ne fait que relayer vers l’app ; elle ne peut pas
   la lancer.
2. **Autoriser les agents IA externes** est-il activé, dans **Réglages ▸ Agent IA** ?
3. Le client pointe-t-il vers le Verbinal que vous avez aujourd’hui ? Une app déplacée ou supprimée ne
   peut pas être lancée. **Réglages ▸ Clients MCP** montre la commande actuelle, et la copie.
4. **Réglages ▸ Clients MCP ▸ Diagnostic** vérifie chaque maillon et répare ce qu’il peut.
5. Quittez complètement l’app de l’assistant et rouvrez-la.

Si l’assistant se connecte mais ne peut rien faire, il attend que vous autorisiez sa session : cherchez la
fenêtre **Un assistant veut ouvrir une session**. Une modification qu’il a proposée attend dans
**En attente**, et expire après trois heures. Voir [Travailler avec un assistant IA](12-ai-assistant.md).

## La langue n’a pas changé

macOS applique la langue d’une app à son démarrage : après avoir changé
**Réglages ▸ Général ▸ Langue**, cliquez sur **Redémarrer maintenant**.

## Signaler un problème

1. Ouvrez **À propos de Verbinal** et cliquez sur **Copier les détails** : la version de l’app, macOS, le
   Mac et la façon dont Verbinal a été installé.
2. Choisissez **Aide ▸ Signaler un problème**, et collez les détails avec ce que vous avez fait et ce qui
   s’est passé.
3. Pour un problème avec un assistant, exportez son journal de session
   (**Réglages ▸ Agent IA ▸ Journaux de session** ▸ **Exporter**) et joignez-le : il contient ce qui
   s’est passé, pas vos données.
