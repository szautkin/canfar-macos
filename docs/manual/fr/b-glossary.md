# Glossaire

| Terme | Sens |
|---|---|
| **ADQL** | Astronomical Data Query Language : le langage proche du SQL du service TAP de l’archive. L’onglet **ADQL** de Rechercher l’écrit et l’exécute. |
| **Allocation** | Les ressources de calcul que votre compte CANFAR peut utiliser : cœurs, mémoire et GPU des sessions, des tâches en lot et du Calcul à distance. |
| **Tâche en lot** | Un conteneur sur CANFAR qui exécute une seule commande sans fenêtre, puis se termine. Aussi appelée session *headless* (sans interface). Voir [Tâches en lot](07-batch-jobs.md). |
| **Blink** | Alterner deux images au même endroit, pour voir ce qui a changé. |
| **CADC** | Le Centre canadien de données astronomiques : l’archive où cherche Verbinal, et les comptes avec lesquels il se connecte. |
| **Niveau d’étalonnage** | Le degré de traitement d’un produit : 0 brut, au format propre à l’instrument ; 1 brut, dans un format standard comme FITS ; 2 étalonné ; 3 construit à partir de plusieurs, comme un empilement ou une mosaïque ; 4 un produit d’analyse, comme un catalogue. **Niv. étalonnage** dans Rechercher. |
| **CANFAR** | Le réseau canadien de recherche astronomique avancée : la plateforme scientifique où tournent les sessions, les tâches en lot et le Calcul à distance, et votre stockage VOSpace. |
| **CAOM-2** | Le Common Archive Observation Model : la façon dont le CADC décrit une observation, ses plans (produits) et leurs artéfacts (fichiers). |
| **CARTA** | Le Cube Analysis and Rendering Tool for Astronomy, lancé comme session CANFAR. |
| **Collection** | L’archive à laquelle appartient une observation : CFHT, HST, JWST, JCMT, GEMINI, … |
| **Session contribuée** | Une session dont l’image a été contribuée à CANFAR, comme une application web. Le Calcul à distance en est une. |
| **Cube** | Une image FITS à trois axes, en général longueur d’onde ou vitesse : un spectre à chaque pixel. Voir [Visionneuse Cube](05-cube-viewer.md). |
| **Découpe** | La partie d’un fichier dont vous avez besoin, découpée par le CADC avant le téléchargement (avec son service SODA). |
| **DataLink** | Le service du CADC qui liste les fichiers, aperçus et découpes d’une observation. |
| **Train de données** | Les listes sous le formulaire de Rechercher (bande, collection, instrument, filtre…) qui se restreignent l’une l’autre au fil de vos choix. |
| **Régions DS9** | Le format de fichier de régions de SAOImage DS9 ; Verbinal y exporte les marques. |
| **Firefly** | Une visionneuse web de données astronomiques, lancée comme session CANFAR. |
| **FITS** | Flexible Image Transport System : le format de fichier des images, cubes et tables astronomiques. Les fichiers `.fz` sont des FITS compressés avec fpack. |
| **Harbor** | Le logiciel du registre d’images de CANFAR, `images.canfar.net`. Son **secret CLI** est le mot de passe du registre. |
| **HDU** | Header Data Unit : une partie d’un fichier FITS, une image ou une table avec son en-tête. Un fichier peut en contenir beaucoup. |
| **Image** (de conteneur) | Ce qu’exécute une session ou une tâche CANFAR : un système d’exploitation avec ses logiciels, gardé dans un registre. |
| **IVOA** | L’International Virtual Observatory Alliance, qui définit TAP, DataLink, SODA, VOSpace et le registre des services. |
| **Marque** | Votre annotation sur une image ou un cube : cercle, rectangle, légende ou texte, gardée avec le fichier. À ne pas confondre avec une indication. |
| **MCP** | Le Model Context Protocol, par lequel des assistants IA comme Claude utilisent les outils de Verbinal. |
| **MJD** | Date julienne modifiée : les jours depuis le 17 novembre 1858, utilisée pour les heures d’observation. |
| **Calepin** | Un calepin (notebook) Jupyter : code, résultats et texte dans un seul document, lancé comme session CANFAR. |
| **Plan** | Un produit d’une observation dans CAOM-2, comme les données brutes ou une image étalonnée. |
| **Sonde** | La petite tâche en lot que la Découverte d’images lance dans une image pour lister ses paquets. |
| **Publisher ID** | L’identifiant d’un plan d’observation au CADC, comme `ivo://cadc.nrc.ca/HST?…`. |
| **Registre** | Deux choses : le registre IVOA, où Verbinal trouve les services du CADC ; et un registre de conteneurs, où sont gardées les images. |
| **Résolveur** | Le service qui transforme un nom (M31, une supernova) en position : SIMBAD, NED ou VizieR, par le CADC. |
| **Session** | Un conteneur interactif sur CANFAR : un calepin, un bureau, CARTA, Firefly ou une application contribuée. |
| **Skaha** | Le service de CANFAR qui exécute les sessions et les tâches en lot. |
| **SODA** | Server-side Operations for Data Access : le service IVOA avec lequel le CADC découpe les fichiers. |
| **Étirement** | La façon dont les valeurs des pixels deviennent de la luminosité : linéaire, logarithmique, racine carrée, carré ou asinh. |
| **TAP** | Table Access Protocol : le service IVOA qui répond aux requêtes ADQL. |
| **VizieR** | Le service de catalogues du CDS à Strasbourg. |
| **VOSpace** | Le standard IVOA de stockage : votre stockage CANFAR. Voir [Stockage](09-storage.md). |
| **WCS** | World Coordinate System : les mots-clés d’en-tête qui relient les pixels aux positions célestes et aux longueurs d’onde. |
| **x1d** | Un fichier HST qui contient un spectre extrait à une dimension, sous forme de table. |
